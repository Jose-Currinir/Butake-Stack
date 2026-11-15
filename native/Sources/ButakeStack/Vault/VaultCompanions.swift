import Foundation

/// Files of a backup that only carry values for another one: `X.p12.pass` (the certificate's password),
/// `CREDENTIALS.txt` beside a keystore (store password, alias, key password), `fastlane.env` beside a
/// `.p8` (Key ID and Issuer ID) and one-line files such as `FIREBASE_APP_ID.txt`.
///
/// The scan only learns which fields a companion brings; its values are read while importing, go
/// straight into the item's fields (encrypted with the index) and are never shown, logged or kept
/// anywhere else.
enum VaultCompanions {
    enum Source: String, Hashable, Sendable { case password, credentials, fastlane, value }

    /// A companion attached to a file of the scan. `certain` when its name or its folder leave no doubt;
    /// otherwise it is only proposed, and taken when the user accepts it in the preview.
    struct Companion: Hashable, Sendable {
        var url: URL
        var name: String
        var source: Source
        var roles: [VaultField.Role]
        var certain: Bool
        var accepted: Bool
        var used: Bool { certain || accepted }
    }

    static let maximumSize = 64 * 1024

    // MARK: What a file is

    static func source(of name: String) -> Source? {
        let lower = name.lowercased()
        if passwordTarget(name) != nil { return .password }
        if ["credentials.txt", "credenciales.txt", "credentials.md", "credenciales.md", "keystore.properties", "key.properties"].contains(lower) { return .credentials }
        if lower == "fastlane.env" || lower.hasPrefix(".env.fastlane") || lower.hasSuffix(".fastlane.env") { return .fastlane }
        if name.firstMatch(of: /^[A-Z][A-Z0-9_]{2,60}\.txt$/) != nil, !["README.TXT", "CREDENTIALS.TXT", "CREDENCIALES.TXT"].contains(name.dataCapitals) { return .value }
        return nil
    }

    /// `dist.p12.pass` → `dist.p12`; `dist.clave` → `dist`; `upload-password.txt` → `upload`.
    static func passwordTarget(_ name: String) -> String? {
        if let match = name.firstMatch(of: /^(.+)\.(?i:pass|clave|password|passwd|pwd)$/) { return String(match.1) }
        if let match = name.firstMatch(of: /^(.+)[._-](?i:pass|password|clave)\.txt$/) { return String(match.1) }
        return nil
    }

    /// Small text files only.
    static func text(_ url: URL) -> String? {
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize, size <= maximumSize,
              let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: Reading values

    /// The first line of a password file, without its line break (inner and edge spaces are kept).
    static func password(_ text: String) -> String? {
        let line = text.components(separatedBy: .newlines).first ?? ""
        return line.isEmpty ? nil : line
    }

    /// One line, or nothing: a value file with more is a note.
    static func value(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 512, !trimmed.contains(where: \.isNewline) else { return nil }
        return trimmed
    }

    /// «Store password: …», «Alias = …», «Key password: la misma»… in any order, with bullets or not.
    static func credentials(_ text: String) -> [VaultField.Role: String] {
        var out: [VaultField.Role: String] = [:]
        var keyFreeText: String?
        var plain: String?
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "-*•> \t"))
            guard let separator = line.firstIndex(where: { $0 == ":" || $0 == "=" }) else { continue }
            let key = line[..<separator].folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es"))
                .trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "*", with: "")
            var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            // «**Store password:** valor»: the closing mark of a bold label is not part of the value.
            for mark in ["**", "__"] where value.hasPrefix(mark + " ") {
                value = String(value.dropFirst(mark.count)).trimmingCharacters(in: .whitespaces)
            }
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" || first == "`" { value = String(value.dropFirst().dropLast()) }
            guard !value.isEmpty else { continue }
            let password = key.contains("pass") || key.contains("contrasena") || key.contains("clave")
            if key.contains("alias") { out[.alias] = out[.alias] ?? value }
            else if password && (key.contains("store") || key.contains("almacen")) { out[.storePassword] = out[.storePassword] ?? value }
            else if password && (key.contains("key") || key.contains("llave")) { keyFreeText = keyFreeText ?? value }
            else if password && plain == nil { plain = value }
        }
        if out[.storePassword] == nil, let plain { out[.storePassword] = plain }
        if let key = keyFreeText {
            // «la misma», «igual», «same as store»: the key password is the store's.
            let lower = key.lowercased()
            let same = key.count <= 40 && ["misma", "mismo", "igual", "same"].contains { lower.contains($0) }
            if same { if let store = out[.storePassword] { out[.keyPassword] = store } } else { out[.keyPassword] = key }
        }
        return out
    }

    /// Key ID and Issuer ID of App Store Connect, whatever the variables are called.
    static func fastlane(_ text: String) -> [VaultField.Role: String] {
        var out: [VaultField.Role: String] = [:]
        for (key, value) in DotEnv.parse(text) where !value.isEmpty {
            let upper = key.dataCapitals
            if upper.contains("ISSUER") { out[.issuerId] = out[.issuerId] ?? value }
            else if upper.contains("KEY_ID") || upper.hasSuffix("KEYID") { out[.keyId] = out[.keyId] ?? value }
        }
        return out
    }

    /// What a companion would bring to a file of `kind`, read from disk.
    static func values(_ companion: Companion, for kind: VaultItemKind) -> [VaultField.Role: String] {
        guard let text = text(companion.url) else { return [:] }
        switch companion.source {
        case .password: return password(text).map { [kind == .androidKeystore ? .storePassword : .password: $0] } ?? [:]
        case .credentials:
            let found = credentials(text)
            guard kind != .androidKeystore else { return found }
            // Beside a certificate, the only password it can bring is the certificate's.
            return found[.storePassword].map { [.password: $0] } ?? [:]
        case .fastlane: return fastlane(text)
        case .value: return value(text).map { [.token: $0] } ?? [:]
        }
    }

    /// The roles only, for the preview: values are read and dropped right away.
    static func roles(_ companion: Companion, for kind: VaultItemKind) -> [VaultField.Role] {
        values(companion, for: kind).keys.sorted { $0.rawValue < $1.rawValue }
    }

    // MARK: Fields of the item

    /// The fields the accepted companions bring, merged into `fields`: an empty field of the same role
    /// takes the value; one that already has a value (from a `.datos.txt`) keeps it.
    static func merge(_ companions: [Companion], kind: VaultItemKind, name: String, into fields: inout [VaultField]) {
        for companion in companions where companion.used {
            for (role, value) in values(companion, for: kind).sorted(by: { $0.key.rawValue < $1.key.rawValue }) {
                if let position = fields.firstIndex(where: { $0.role == role }) {
                    if fields[position].value.isEmpty { fields[position].value = value }
                    continue
                }
                fields.append(field(role, value: value, kind: kind, companion: companion))
            }
        }
    }

    private static func field(_ role: VaultField.Role, value: String, kind: VaultItemKind, companion: Companion) -> VaultField {
        let secret = [.password, .storePassword, .keyPassword, .passphrase, .token].contains(role)
        let template = kind.templateFields.first { $0.role == role }?.envVar
        let variable: String?
        switch role {
        case .token: variable = (companion.name as NSString).deletingPathExtension
        case .password where kind == .iosCertificate: variable = "IOS_CERTIFICATE_PASSWORD"
        default: variable = template
        }
        return VaultField(role: role, label: role == .token ? (companion.name as NSString).deletingPathExtension : "", value: value, secret: secret, envVar: variable)
    }
}
