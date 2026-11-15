import CryptoKit
import Foundation
import Security

/// Reads what can be known of a file locally, without network: kind by name and content, expiry and
/// team of provisioning profiles and certificates, Firebase project and packages, service account
/// email, App Store Connect key id, keystore fingerprints (with Stack's own Java, when installed).
/// Private keys and passwords are never copied into the metadata.
enum VaultInspector {
    // MARK: Kind

    static func detectKind(name: String, data: Data?) -> VaultItemKind {
        let lower = name.lowercased()
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "jks", "keystore", "bks": return .androidKeystore
        case "p12", "pfx", "cer": return .iosCertificate
        case "mobileprovision", "provisionprofile": return .provisioningProfile
        case "p8": return .appStoreKey
        default: break
        }
        if lower == "google-services.json" { return .googleServices }
        if lower.hasPrefix("googleservice-info") && ext == "plist" { return .googleServiceInfo }
        if lower == ".env" || lower.hasPrefix(".env.") || ext == "env" { return .envFile }
        if ext == "json" {
            if let data, let object = try? JSONSerialization.jsonObject(with: data.prefix(2_000_000)) as? [String: Any],
               object["type"] as? String == "service_account" { return .serviceAccount }
            return .file
        }
        if ["id_rsa", "id_ed25519", "id_ecdsa", "id_dsa"].contains(where: { lower.hasPrefix($0) }) || ext == "pub" { return .sshKey }
        if ["pem", "key"].contains(ext) {
            guard let data, let text = String(data: data.prefix(200), encoding: .utf8), text.contains("PRIVATE KEY") else { return .file }
            // A `.key` is a certificate's private key unless it is an OpenSSH one; a `.pem` stays an SSH
            // key unless the backup's layout says otherwise (`VaultFolder.associate`).
            return ext == "key" && !text.contains("OPENSSH") ? .certificateKey : .sshKey
        }
        if ["md", "txt", "markdown"].contains(ext) || lower.hasPrefix("readme") { return .note }
        return .file
    }

    /// Fields guessed from the file name (the App Store Connect key id is in AuthKey_<ID>.p8).
    static func suggestedFields(kind: VaultItemKind, fileName: String) -> [VaultField] {
        var fields = kind.templateFields
        if kind == .appStoreKey, let id = appStoreKeyId(fileName), let index = fields.firstIndex(where: { $0.role == .keyId }) {
            fields[index].value = id
        }
        return fields
    }

    static func appStoreKeyId(_ fileName: String) -> String? {
        guard let match = fileName.firstMatch(of: /^AuthKey_([A-Z0-9]{6,20})\.p8$/) else { return nil }
        return String(match.1)
    }

    // MARK: Metadata

    /// `keytool`: Stack's own JDK, when one is installed; without it the fingerprints are left out.
    static func inspect(item: VaultItem, data: Data, fileName: String, keytool: URL? = nil, disk: VaultDisk? = nil) -> VaultMetadata {
        switch item.kind {
        case .provisioningProfile: return provisioningProfile(data)
        case .iosCertificate: return certificate(data, password: item.field(.password)?.value ?? "", fileName: fileName)
        case .googleServices: return googleServices(data)
        case .googleServiceInfo: return googleServiceInfo(data)
        case .serviceAccount: return serviceAccount(data)
        case .appStoreKey, .apnsKey:
            var meta = VaultMetadata()
            if let id = appStoreKeyId(fileName) { meta.entries.append(.init(key: "vault.meta.keyId", value: id)) }
            return meta
        case .androidKeystore:
            guard let disk else { return VaultMetadata() }
            guard let keytool else { return VaultMetadata(problem: "vault.meta.noJava") }
            let password = item.field(.storePassword)?.value ?? ""
            guard !password.isEmpty else { return VaultMetadata(problem: "vault.meta.needsPassword") }
            return keystore(data, fileName: fileName, password: password, alias: item.field(.alias)?.value, keytool: keytool, disk: disk)
        case .envFile:
            let keys = DotEnv.parse(String(decoding: data.prefix(1_000_000), as: UTF8.self)).map(\.0)
            var meta = VaultMetadata()
            meta.entries.append(.init(key: "vault.meta.variables", value: "\(keys.count)"))
            if !keys.isEmpty { meta.entries.append(.init(key: "vault.meta.keys", value: keys.prefix(40).joined(separator: ", "))) }
            return meta
        case .sshKey: return sshKey(data, fileName: fileName)
        case .certificateKey:
            // Only the kind of key, from its first line; the key itself is never read into the metadata.
            var meta = VaultMetadata()
            if let line = String(decoding: data.prefix(200), as: UTF8.self).split(separator: "\n").first, line.hasPrefix("-----BEGIN ") {
                meta.entries.append(.init(key: "vault.meta.algorithm", value: line.replacingOccurrences(of: "-----BEGIN ", with: "").replacingOccurrences(of: "-----", with: "")))
            }
            return meta
        default: return VaultMetadata()
        }
    }

    // MARK: Provisioning profile (CMS → plist)

    static func provisioningPlist(_ data: Data) -> [String: Any]? {
        var content: Data?
        var decoder: CMSDecoder?
        if CMSDecoderCreate(&decoder) == errSecSuccess, let decoder {
            let updated = data.withUnsafeBytes { buffer in
                buffer.baseAddress.map { CMSDecoderUpdateMessage(decoder, $0, buffer.count) } ?? errSecParam
            }
            var copied: CFData?
            if updated == errSecSuccess, CMSDecoderFinalizeMessage(decoder) == errSecSuccess,
               CMSDecoderCopyContent(decoder, &copied) == errSecSuccess { content = copied as Data? }
        }
        // The signed content is the plist in clear; take it directly if the decoder refused the envelope.
        if content == nil, let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) {
            content = data[start.lowerBound..<end.upperBound]
        }
        guard let content else { return nil }
        return (try? PropertyListSerialization.propertyList(from: content, format: nil)) as? [String: Any]
    }

    static func provisioningProfile(_ data: Data) -> VaultMetadata {
        guard let plist = provisioningPlist(data) else { return VaultMetadata(problem: "vault.meta.unreadable") }
        var meta = VaultMetadata()
        meta.expires = plist["ExpirationDate"] as? Date
        if let name = plist["Name"] as? String { meta.entries.append(.init(key: "vault.meta.profileName", value: name)) }
        let team = [plist["TeamName"] as? String, (plist["TeamIdentifier"] as? [String])?.first.map { "(\($0))" }].compactMap { $0 }.joined(separator: " ")
        if !team.isEmpty { meta.entries.append(.init(key: "vault.meta.team", value: team)) }
        let entitlements = plist["Entitlements"] as? [String: Any] ?? [:]
        if let appId = entitlements["application-identifier"] as? String { meta.entries.append(.init(key: "vault.meta.appId", value: appId)) }
        let type: String
        if plist["ProvisionsAllDevices"] as? Bool == true { type = "enterprise" }
        else if plist["ProvisionedDevices"] != nil { type = entitlements["get-task-allow"] as? Bool == true ? "development" : "adhoc" }
        else { type = "appstore" }
        meta.entries.append(.init(key: "vault.meta.profileType", value: type))
        if let devices = plist["ProvisionedDevices"] as? [Any] { meta.entries.append(.init(key: "vault.meta.devices", value: "\(devices.count)")) }
        // The certificates it lets sign with (SHA-1 of each), to check them against the vault's.
        let certificates = (plist["DeveloperCertificates"] as? [Data] ?? []).map(sha1)
        if !certificates.isEmpty { meta.entries.append(.init(key: "vault.meta.certificates", value: certificates.joined(separator: ", "))) }
        let capabilities = VaultSigning.capabilities(entitlements)
        if !capabilities.isEmpty { meta.entries.append(.init(key: "vault.meta.entitlements", value: capabilities.joined(separator: " · "))) }
        if let push = entitlements["aps-environment"] as? String { meta.entries.append(.init(key: "vault.meta.push", value: push)) }
        return meta
    }

    // MARK: Certificates (.p12 with its password, in memory only; .cer)

    static func certificate(_ data: Data, password: String, fileName: String) -> VaultMetadata {
        let certificate: SecCertificate
        if fileName.lowercased().hasSuffix(".cer") {
            guard let cer = SecCertificateCreateWithData(nil, data as CFData) else { return VaultMetadata(problem: "vault.meta.unreadable") }
            certificate = cer
        } else {
            let options: [String: Any] = [kSecImportExportPassphrase as String: password, kSecImportToMemoryOnly as String: true]
            var items: CFArray?
            let status = SecPKCS12Import(data as CFData, options as CFDictionary, &items)
            guard status == errSecSuccess, let list = items as? [[String: Any]], let first = list.first else {
                return VaultMetadata(problem: status == errSecAuthFailed || status == errSecPkcs12VerifyFailure ? (password.isEmpty ? "vault.meta.needsPassword" : "vault.meta.wrongPassword") : "vault.meta.unreadable")
            }
            if let object = first[kSecImportItemIdentity as String] as AnyObject?, CFGetTypeID(object) == SecIdentityGetTypeID() {
                let identity = unsafeDowncast(object, to: SecIdentity.self)
                var cert: SecCertificate?
                guard SecIdentityCopyCertificate(identity, &cert) == errSecSuccess, let cert else { return VaultMetadata(problem: "vault.meta.unreadable") }
                certificate = cert
            } else if let chain = first[kSecImportItemCertChain as String] as? [SecCertificate], let cert = chain.first {
                certificate = cert
            } else { return VaultMetadata(problem: "vault.meta.unreadable") }
        }
        return certificateMetadata(certificate)
    }

    static func certificateMetadata(_ certificate: SecCertificate) -> VaultMetadata {
        var meta = VaultMetadata()
        meta.expires = SecCertificateCopyNotValidAfterDate(certificate) as Date?
        if let summary = SecCertificateCopySubjectSummary(certificate) as String? {
            meta.entries.append(.init(key: "vault.meta.subject", value: summary))
        }
        // Apple's signing certificates end their name with the team: "Apple Distribution: Nombre (ABCDE12345)".
        if let summary = SecCertificateCopySubjectSummary(certificate) as String?, let match = summary.firstMatch(of: /\(([A-Z0-9]{10})\)\s*$/) {
            meta.entries.append(.init(key: "vault.meta.teamId", value: String(match.1)))
        }
        meta.entries.append(.init(key: "vault.meta.sha1", value: sha1(SecCertificateCopyData(certificate) as Data)))
        return meta
    }

    /// «AB:CD:…» of a certificate's DER bytes, as keytool and Keychain Access show it.
    static func sha1(_ der: Data) -> String {
        Insecure.SHA1.hash(data: der).map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    // MARK: Firebase and Google

    static func googleServices(_ data: Data) -> VaultMetadata {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return VaultMetadata(problem: "vault.meta.unreadable") }
        var meta = VaultMetadata()
        let project = object["project_info"] as? [String: Any] ?? [:]
        if let id = project["project_id"] as? String { meta.entries.append(.init(key: "vault.meta.projectId", value: id)) }
        if let number = project["project_number"] as? String { meta.entries.append(.init(key: "vault.meta.projectNumber", value: number)) }
        let packages = (object["client"] as? [[String: Any]] ?? []).compactMap {
            (($0["client_info"] as? [String: Any])?["android_client_info"] as? [String: Any])?["package_name"] as? String
        }
        if !packages.isEmpty { meta.entries.append(.init(key: "vault.meta.packages", value: packages.joined(separator: ", "))) }
        return meta
    }

    static func googleServiceInfo(_ data: Data) -> VaultMetadata {
        guard let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else { return VaultMetadata(problem: "vault.meta.unreadable") }
        var meta = VaultMetadata()
        if let id = plist["PROJECT_ID"] as? String { meta.entries.append(.init(key: "vault.meta.projectId", value: id)) }
        if let bundle = plist["BUNDLE_ID"] as? String { meta.entries.append(.init(key: "vault.meta.bundleId", value: bundle)) }
        if let sender = plist["GCM_SENDER_ID"] as? String { meta.entries.append(.init(key: "vault.meta.projectNumber", value: sender)) }
        return meta
    }

    /// Email and project only; `private_key` is never read into the metadata.
    static func serviceAccount(_ data: Data) -> VaultMetadata {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["type"] as? String == "service_account" else {
            return VaultMetadata(problem: "vault.meta.unreadable")
        }
        var meta = VaultMetadata()
        if let email = object["client_email"] as? String { meta.entries.append(.init(key: "vault.meta.clientEmail", value: email)) }
        if let id = object["project_id"] as? String { meta.entries.append(.init(key: "vault.meta.projectId", value: id)) }
        if let keyId = object["private_key_id"] as? String, keyId.count > 8 {
            meta.entries.append(.init(key: "vault.meta.privateKeyId", value: String(keyId.prefix(8)) + "…"))
        }
        return meta
    }

    // MARK: SSH

    static func sshKey(_ data: Data, fileName: String) -> VaultMetadata {
        let text = String(decoding: data.prefix(64_000), as: UTF8.self)
        var meta = VaultMetadata()
        if fileName.lowercased().hasSuffix(".pub") || text.hasPrefix("ssh-") || text.hasPrefix("ecdsa-") {
            let parts = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: " ", maxSplits: 2).map(String.init)
            if let algorithm = parts.first { meta.entries.append(.init(key: "vault.meta.algorithm", value: algorithm)) }
            if parts.count > 1, let blob = Data(base64Encoded: parts[1]) {
                let digest = Data(SHA256.hash(data: blob)).base64EncodedString().trimmingCharacters(in: CharacterSet(charactersIn: "="))
                meta.entries.append(.init(key: "vault.meta.fingerprint", value: "SHA256:" + digest))
            }
            if parts.count > 2 { meta.entries.append(.init(key: "vault.meta.comment", value: parts[2])) }
        } else if let line = text.split(separator: "\n").first, line.hasPrefix("-----BEGIN ") {
            let type = line.replacingOccurrences(of: "-----BEGIN ", with: "").replacingOccurrences(of: "-----", with: "")
            meta.entries.append(.init(key: "vault.meta.algorithm", value: type))
        }
        return meta
    }

    // MARK: Android keystore (keytool from Stack's JDK)

    /// The `keytool` to read keystores with: Stack's own JDK, else the system's (`java_home`), else none.
    static func keytool() -> URL? { stackKeytool() ?? systemKeytool() }

    /// The JDK macOS knows of, asked to `java_home` (never `/usr/bin/keytool`, whose stub offers to
    /// install Java when there is none).
    static func systemKeytool() -> URL? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/libexec/java_home")
        let output = Pipe()
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard FileManager.default.isExecutableFile(atPath: "/usr/libexec/java_home"), (try? process.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let home = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0, home.hasPrefix("/") else { return nil }
        let tool = URL(fileURLWithPath: home).appendingPathComponent("bin/keytool")
        return FileManager.default.isExecutableFile(atPath: tool.path) ? tool : nil
    }

    /// Newest `keytool` of the JDKs Stack installed (`runtimes/jdk/<version>`), if any.
    static func stackKeytool() -> URL? {
        let jdks = Folder.baseURL.appendingPathComponent("runtimes/jdk", isDirectory: true)
        let versions = ((try? FileManager.default.contentsOfDirectory(atPath: jdks.path)) ?? [])
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
        for version in versions {
            let tool = jdks.appendingPathComponent(version).appendingPathComponent("Contents/Home/bin/keytool")
            if FileManager.default.isExecutableFile(atPath: tool.path) { return tool }
        }
        return nil
    }

    /// The password reaches keytool through its environment (`-storepass:env`), never its arguments.
    static func keystore(_ data: Data, fileName: String, password: String, alias: String?, keytool: URL, disk: VaultDisk) -> VaultMetadata {
        guard let copy = try? disk.temporaryCopy(data, name: fileName) else { return VaultMetadata(problem: "vault.meta.unreadable") }
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        var arguments = ["-J-Duser.language=en", "-J-Duser.country=US", "-J-Duser.timezone=UTC", "-list", "-v", "-keystore", copy.path, "-storepass:env", "BUTAKE_VAULT_STOREPASS"]
        if let alias, !alias.isEmpty { arguments += ["-alias", alias] }
        let process = Process()
        process.executableURL = keytool
        process.arguments = arguments
        var environment = ["PATH": "/usr/bin:/bin", "BUTAKE_VAULT_STOREPASS": password]
        if let home = ProcessInfo.processInfo.environment["HOME"] { environment["HOME"] = home }
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do { try process.run() } catch { return VaultMetadata() }
        let deadline = DispatchTime.now() + 20
        let reader = DispatchQueue.global()
        nonisolated(unsafe) var bytes = Data()
        let done = DispatchSemaphore(value: 0)
        reader.async { bytes = output.fileHandleForReading.readDataToEndOfFile(); done.signal() }
        if done.wait(timeout: deadline) == .timedOut { process.terminate(); return VaultMetadata(problem: "vault.meta.unreadable") }
        process.waitUntilExit()
        let text = String(decoding: bytes, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            if text.contains("does not exist") { return VaultMetadata(problem: "vault.meta.wrongAlias") }
            return VaultMetadata(problem: text.contains("password was incorrect") || text.contains("password") ? "vault.meta.wrongPassword" : "vault.meta.unreadable")
        }
        return parseKeytool(text)
    }

    /// The first certificate of `keytool -list -v` (English locale, UTC dates).
    static func parseKeytool(_ text: String) -> VaultMetadata {
        var meta = VaultMetadata()
        func first(_ prefix: String) -> String? {
            text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.first { $0.hasPrefix(prefix) }
                .map { String($0.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces) }
        }
        if let alias = first("Alias name:") { meta.entries.append(.init(key: "vault.meta.alias", value: alias)) }
        if let owner = first("Owner:") { meta.entries.append(.init(key: "vault.meta.subject", value: owner)) }
        if let sha1 = first("SHA1:") { meta.entries.append(.init(key: "vault.meta.sha1", value: sha1)) }
        if let sha256 = first("SHA256:") { meta.entries.append(.init(key: "vault.meta.sha256", value: sha256)) }
        if let valid = first("Valid from:"), let range = valid.range(of: "until: ") {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "EEE MMM dd HH:mm:ss zzz yyyy"
            meta.expires = formatter.date(from: String(valid[range.upperBound...]))
        }
        return meta
    }
}
