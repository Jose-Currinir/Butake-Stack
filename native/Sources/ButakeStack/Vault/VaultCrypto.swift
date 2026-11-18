import CommonCrypto
import CryptoKit
import Foundation

enum VaultError: Error, Equatable {
    case locked, missingKey, keychain(Int32), corrupt, wrongPassword, unsupported, tooLarge, invalidName, io, authentication

    /// Localization key of the message shown to the user (never with values).
    var messageKey: String {
        switch self {
        case .locked: "vault.error.locked"
        case .missingKey: "vault.error.missingKey"
        case .keychain: "vault.error.keychain"
        case .corrupt: "vault.error.corrupt"
        case .wrongPassword: "vault.error.wrongPassword"
        case .unsupported: "vault.error.unsupported"
        case .tooLarge: "vault.error.tooLarge"
        case .invalidName: "vault.error.invalidName"
        case .io: "vault.error.io"
        case .authentication: "vault.error.authentication"
        }
    }
}

/// AES-256-GCM with CryptoKit; every sealed box carries its own random nonce and authenticates
/// `context` (additional data), so a blob can't be swapped for another one or for the index.
enum VaultCrypto {
    static func seal(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        guard let combined = try AES.GCM.seal(data, using: key, authenticating: Data(context.utf8)).combined else { throw VaultError.corrupt }
        return combined
    }

    static func open(_ data: Data, key: SymmetricKey, context: String) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: data)
            return try AES.GCM.open(box, using: key, authenticating: Data(context.utf8))
        } catch { throw VaultError.corrupt }
    }

    static func newKey() -> SymmetricKey { SymmetricKey(size: .bits256) }

    static func randomBytes(_ count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        let status = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed")
        return Data(bytes)
    }

    /// PBKDF2-HMAC-SHA256 (CommonCrypto) → 256-bit key.
    static func deriveKey(password: String, salt: Data, iterations: Int) throws -> SymmetricKey {
        guard iterations > 0, iterations <= UInt32.max else { throw VaultError.unsupported }
        let passwordBytes = Array(password.utf8)
        var derived = [UInt8](repeating: 0, count: 32)
        let status = salt.withUnsafeBytes { saltBuffer in
            passwordBytes.withUnsafeBufferPointer { passwordBuffer in
                CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                     passwordBuffer.baseAddress.map { UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self) },
                                     passwordBytes.count,
                                     saltBuffer.bindMemory(to: UInt8.self).baseAddress, salt.count,
                                     CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), UInt32(iterations),
                                     &derived, derived.count)
            }
        }
        guard status == kCCSuccess else { throw VaultError.unsupported }
        defer { derived.withUnsafeMutableBufferPointer { $0.initialize(repeating: 0) } }
        return SymmetricKey(data: derived)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// The `.butakevault` backup: a password-protected, versioned file (see docs/boveda-formato.md).
///
///     "BUTAKEVT" (8 bytes) · version (1 byte) · header length (UInt32, big endian) · header (JSON)
///     · AES-256-GCM combined box (nonce 12 · ciphertext · tag 16)
///
/// The key is PBKDF2-HMAC-SHA256 of the password with the header's salt and iterations; everything
/// before the box is authenticated as additional data, so the header can't be altered either.
enum VaultArchive {
    static let magic = Data("BUTAKEVT".utf8)
    static let version: UInt8 = 1
    static let defaultIterations = 600_000
    static let minimumIterations = 100_000
    static let maximumIterations = 10_000_000
    static let minimumPasswordLength = 12
    static let maximumSize = 512 * 1024 * 1024

    struct Header: Codable, Sendable, Equatable {
        var format = "butake-vault"
        var version = 1
        var kdf = "pbkdf2-sha256"
        var iterations: Int
        var salt: String
        var cipher = "aes-256-gcm"
        var created: Date
        /// "all" or the folder name of the one app or service exported.
        var scope: String
        var containers: Int
        var items: Int
    }

    struct Payload: Codable, Sendable, Equatable {
        var containers: [VaultContainer]
        var items: [VaultItem]
        /// Blob id (UUID string) → original bytes.
        var blobs: [String: Data]
    }

    static func encode(_ payload: Payload, password: String, scope: String, iterations: Int = defaultIterations, now: Date = Date()) throws -> Data {
        let salt = VaultCrypto.randomBytes(16)
        let header = Header(iterations: iterations, salt: salt.base64EncodedString(), created: now, scope: scope,
                            containers: payload.containers.count, items: payload.items.count)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        let headerData = try encoder.encode(header)
        var prefix = magic
        prefix.append(version)
        var length = UInt32(headerData.count).bigEndian
        prefix.append(Data(bytes: &length, count: 4))
        prefix.append(headerData)
        let key = try VaultCrypto.deriveKey(password: password, salt: salt, iterations: iterations)
        let body = try encoder.encode(payload)
        guard let box = try AES.GCM.seal(body, using: key, authenticating: prefix).combined else { throw VaultError.corrupt }
        return prefix + box
    }

    /// Reads only the header (to show what a file holds before asking for its password).
    static func header(of data: Data) throws -> (Header, Int) {
        guard data.count > magic.count + 5, data.prefix(magic.count) == magic else { throw VaultError.unsupported }
        guard data[data.startIndex + magic.count] == version else { throw VaultError.unsupported }
        let lengthStart = data.startIndex + magic.count + 1
        let length = data[lengthStart..<lengthStart + 4].reduce(0) { ($0 << 8) | Int($1) }
        let headerStart = lengthStart + 4
        guard length > 0, length < 64 * 1024, data.endIndex - headerStart > length else { throw VaultError.corrupt }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let header = try? decoder.decode(Header.self, from: data[headerStart..<headerStart + length]) else { throw VaultError.corrupt }
        guard header.format == "butake-vault", header.version == 1, header.kdf == "pbkdf2-sha256", header.cipher == "aes-256-gcm" else {
            throw VaultError.unsupported
        }
        return (header, headerStart + length - data.startIndex)
    }

    static func decode(_ data: Data, password: String, minimumIterations: Int = minimumIterations) throws -> (Header, Payload) {
        guard data.count <= maximumSize else { throw VaultError.tooLarge }
        let (header, prefixLength) = try header(of: data)
        guard (minimumIterations...maximumIterations).contains(header.iterations),
              let salt = Data(base64Encoded: header.salt), salt.count >= 16 else { throw VaultError.unsupported }
        let prefix = data.prefix(prefixLength)
        let key = try VaultCrypto.deriveKey(password: password, salt: salt, iterations: header.iterations)
        let plain: Data
        do {
            let box = try AES.GCM.SealedBox(combined: data.dropFirst(prefixLength))
            plain = try AES.GCM.open(box, using: key, authenticating: prefix)
        } catch {
            // GCM can't tell a wrong password from an altered file: both fail authentication.
            throw VaultError.wrongPassword
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: plain) else { throw VaultError.corrupt }
        // Every file the index names must be there, with the hash it says.
        for item in payload.items {
            for file in item.files {
                guard let blob = payload.blobs[file.id.uuidString], VaultCrypto.sha256(blob) == file.sha256 else { throw VaultError.corrupt }
            }
        }
        return (header, payload)
    }
}
