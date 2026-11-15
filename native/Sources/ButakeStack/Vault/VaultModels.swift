import Foundation

/// What the vault holds: apps (with their android/ios/server/terceros sections) and shared services,
/// laid out like the user's master backup folder ("3.CLAVES-APPS"). The whole index is encrypted on
/// disk (see `VaultStore`); nothing here is ever logged or sent anywhere.
struct VaultIndex: Codable, Sendable, Equatable {
    var version = 1
    var containers: [VaultContainer] = []
    var items: [VaultItem] = []
    /// What the last folder import brought and left out: relative paths and counts, never a value.
    var lastImport: VaultImportSummary?

    func items(in container: UUID) -> [VaultItem] { items.filter { $0.container == container } }
    func container(_ id: UUID) -> VaultContainer? { containers.first { $0.id == id } }
    func item(_ id: UUID) -> VaultItem? { items.first { $0.id == id } }
}

/// An app (`<Nombre> (<bundle id>)/`) or a service (`_SERVICIOS/<ruta>/`).
struct VaultContainer: Codable, Sendable, Identifiable, Hashable {
    enum Kind: String, Codable, Sendable { case app, service }
    var id = UUID()
    var kind: Kind
    /// App name, or the service path ("gcp", "cloudflare/cuenta-principal").
    var name: String
    var bundleId: String?
    var notes = ""
    var created = Date()
    /// The Stack project this app belongs to (its id), chosen by the user. Optional and added later:
    /// an index or a `.butakevault` without it opens the same, and an older version ignores it.
    var project: String?

    /// Folder name in the master backup layout.
    var folderName: String {
        switch kind {
        case .app: bundleId.map { $0.isEmpty ? name : "\(name) (\($0))" } ?? name
        case .service: name
        }
    }
    /// The name shown: a service saved by an earlier import as `cloudflare/cuenta` reads «cloudflare»,
    /// with the account under it (`subtitlePath`), never as a path.
    var title: String {
        kind == .service ? (name.split(separator: "/").first.map(String.init) ?? name) : name
    }
    var subtitlePath: String? {
        guard kind == .service else { return nil }
        let parts = name.split(separator: "/").map(String.init)
        return parts.count > 1 ? VaultContainer.accountTitle(parts.dropFirst().joined(separator: "/")) : nil
    }
    /// An account of a service as it is shown: `tunnels/principal` reads «tunnels › principal».
    static func accountTitle(_ account: String) -> String { account.split(separator: "/").joined(separator: " › ") }

    /// "Buky Salud (cl.butake.health)" → ("Buky Salud", "cl.butake.health").
    static func parseAppFolder(_ folder: String) -> (name: String, bundleId: String?) {
        let trimmed = folder.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasSuffix(")"), let open = trimmed.lastIndex(of: "(") else { return (trimmed, nil) }
        let name = trimmed[..<open].trimmingCharacters(in: .whitespaces)
        let id = trimmed[trimmed.index(after: open)..<trimmed.index(before: trimmed.endIndex)].trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, VaultNames.isBundleId(id) else { return (trimmed, nil) }
        return (name, id)
    }
}

/// The four sections of every app folder.
enum VaultSection: String, Codable, Sendable, CaseIterable, Identifiable {
    case android, ios, server, terceros
    var id: String { rawValue }
    /// Its name in the interface; the folder on disk keeps `rawValue`.
    var title: String { L("vault.part.\(rawValue)") }
    /// The name of the part outside the four sections: an app's own files, or what a service holds.
    static func title(_ section: VaultSection?, app: Bool) -> String { section?.title ?? L(app ? "vault.part.none" : "vault.part.content") }
    var symbol: String {
        switch self {
        case .android: "apps.iphone"
        case .ios: "iphone"
        case .server: Symbols.server
        case .terceros: "puzzlepiece.extension"
        }
    }
}

/// The stage an item belongs to. The stored values stay `none`, `test` and `prod`; they are shown with
/// the names projects give their environments (`env.kind.*`): the stage before production is
/// «Preproducción».
enum VaultEnvironment: String, Codable, Sendable, CaseIterable, Identifiable {
    case none, test, prod
    var id: String { rawValue }
    var title: String {
        switch self {
        case .none: L("vault.env.none")
        case .test: L("env.kind.staging")
        case .prod: L("env.kind.production")
        }
    }
    /// The project environment this stage is (same names, colors and symbols); none for `none`.
    var envKind: EnvKind? {
        switch self {
        case .none: nil
        case .test: .staging
        case .prod: .production
        }
    }
}

/// Kinds of things used to sign and deploy, each with its icon and the fields it usually needs.
enum VaultItemKind: String, Codable, Sendable, CaseIterable, Identifiable {
    case androidKeystore, iosCertificate, provisioningProfile, appStoreKey, googleServices, googleServiceInfo,
         serviceAccount, sshKey, envFile, token, note, file,
         /// The private key of a certificate (`.key` PEM), not an SSH key.
         certificateKey,
         /// A `.p8` that sends push notifications, apart from the App Store Connect one.
         apnsKey
    var id: String { rawValue }

    /// A kind a later version adds reads as «Otro archivo» instead of leaving the whole index unreadable.
    init(from decoder: Decoder) throws {
        self = VaultItemKind(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .file
    }

    /// The kind written in `kind` for versions that do not know this one (an APNs key reads there as an
    /// App Store Connect key, a certificate's key as a file); the kind itself goes in `kindDetail`.
    var stored: VaultItemKind {
        switch self {
        case .apnsKey: .appStoreKey
        case .certificateKey: .file
        default: self
        }
    }

    /// What the vault keeps is what signs and publishes an app. A project's `.env` belongs to its
    /// Entornos and Stack's SSH keys to Ajustes › Claves SSH: the vault no longer offers those two
    /// kinds, while the items of them it already holds keep working as before.
    var isRetired: Bool { self == .sshKey || self == .envFile }
    /// The kinds a new item can take.
    static var offered: [VaultItemKind] { allCases.filter { !$0.isRetired } }
    /// The kinds to choose from for an item that already has `current`: the offered ones, and its own.
    static func choices(keeping current: VaultItemKind) -> [VaultItemKind] { allCases.filter { !$0.isRetired || $0 == current } }

    var symbol: String {
        switch self {
        case .androidKeystore: "key.horizontal.fill"
        case .iosCertificate: "checkmark.seal.fill"
        case .provisioningProfile: "doc.badge.gearshape.fill"
        case .appStoreKey: "key.fill"
        case .apnsKey: "bell.badge.fill"
        case .certificateKey: "signature"
        case .googleServices, .googleServiceInfo: "flame.fill"
        case .serviceAccount: "person.badge.key.fill"
        case .sshKey: "terminal.fill"
        case .envFile: "list.bullet.rectangle.fill"
        case .token: "ticket.fill"
        case .note: "note.text"
        case .file: "doc.fill"
        }
    }
    var defaultSection: VaultSection? {
        switch self {
        case .androidKeystore, .googleServices: .android
        case .iosCertificate, .provisioningProfile, .appStoreKey, .googleServiceInfo, .certificateKey, .apnsKey: .ios
        case .sshKey, .envFile: .server
        case .serviceAccount, .token: .terceros
        case .note, .file: nil
        }
    }
    /// Fields offered when an item of this kind is created (all editable afterwards).
    var templateFields: [VaultField] {
        switch self {
        case .androidKeystore:
            [VaultField(role: .alias, secret: false, envVar: "ANDROID_KEY_ALIAS"),
             VaultField(role: .storePassword, secret: true, envVar: "ANDROID_KEYSTORE_PASSWORD"),
             VaultField(role: .keyPassword, secret: true, envVar: "ANDROID_KEY_PASSWORD")]
        case .iosCertificate:
            [VaultField(role: .password, secret: true, envVar: "IOS_CERTIFICATE_PASSWORD")]
        case .appStoreKey:
            [VaultField(role: .keyId, secret: false, envVar: "ASC_KEY_ID"),
             VaultField(role: .issuerId, secret: false, envVar: "ASC_ISSUER_ID")]
        case .apnsKey:
            [VaultField(role: .keyId, secret: false, envVar: "APNS_KEY_ID")]
        case .token:
            [VaultField(role: .token, secret: true, envVar: "")]
        case .sshKey:
            [VaultField(role: .username, secret: false), VaultField(role: .host, secret: false),
             VaultField(role: .passphrase, secret: true)]
        default: []
        }
    }
    /// Environment variable suggested for the file itself (paths or base64 in CI).
    var fileEnvVar: String? {
        switch self {
        case .androidKeystore: "ANDROID_KEYSTORE_BASE64"
        case .iosCertificate: "IOS_CERTIFICATE_P12_BASE64"
        case .provisioningProfile: "IOS_PROVISIONING_PROFILE_BASE64"
        case .appStoreKey: "ASC_KEY_P8"
        case .apnsKey: "APNS_KEY_P8"
        case .certificateKey: "IOS_CERTIFICATE_KEY"
        case .googleServices: "GOOGLE_SERVICES_JSON"
        case .googleServiceInfo: "GOOGLE_SERVICE_INFO_PLIST"
        case .serviceAccount: "GOOGLE_APPLICATION_CREDENTIALS"
        case .sshKey: "SSH_PRIVATE_KEY"
        default: nil
        }
    }
}

/// A named value of an item. `role` marks the well-known ones (used by metadata and READMEs).
struct VaultField: Codable, Sendable, Identifiable, Hashable {
    enum Role: String, Codable, Sendable, CaseIterable {
        case alias, storePassword, keyPassword, password, keyId, issuerId, username, host, passphrase, token, url, custom
    }
    var id = UUID()
    var role: Role = .custom
    var label = ""
    var value = ""
    var secret: Bool
    var envVar: String?

    /// The label shown: the custom one, or the role's.
    var title: String { label.isEmpty && role != .custom ? L("vault.field.\(role.rawValue)") : label }
}

/// A stored file: the encrypted blob is `blobs/<id>.bin`; the hash is of the original bytes.
struct VaultFile: Codable, Sendable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var size: Int
    var sha256: String
}

/// What was read from the files locally, without network. `entries` hold localization keys and
/// non-secret values (team, project, fingerprint…); private keys are never copied here.
struct VaultMetadata: Codable, Sendable, Hashable {
    struct Entry: Codable, Sendable, Hashable { var key: String; var value: String }
    var expires: Date?
    var entries: [Entry] = []
    var problem: String?
    func value(_ key: String) -> String? { entries.first { $0.key == key }?.value }
}

struct VaultItem: Codable, Sendable, Identifiable, Hashable {
    var id = UUID()
    var container: UUID
    var section: VaultSection?
    var kind: VaultItemKind
    var name: String
    var files: [VaultFile] = []
    var fields: [VaultField] = []
    var notes = ""
    var environment: VaultEnvironment = .none
    var created = Date()
    var updated = Date()
    var metadata = VaultMetadata()
    /// The account of a service this item belongs to: the subfolder it came from in the backup
    /// (`cloudflare/<cuenta>/…` → «cuenta», `tunnels/principal`). Nil for an app's items and for what
    /// sits in the service itself. Optional and added later: an older version ignores it.
    var account: String?

    func field(_ role: VaultField.Role) -> VaultField? { fields.first { $0.role == role } }

    private enum CodingKeys: String, CodingKey {
        case id, container, section, kind, kindDetail, name, files, fields, notes, environment, created, updated, metadata, account
    }

    enum Expiry: Int, Comparable { case ok, soon, expired
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    /// Within 30 days counts as soon.
    func expiry(now: Date = Date()) -> Expiry? {
        guard let date = metadata.expires else { return nil }
        if date < now { return .expired }
        if date.timeIntervalSince(now) < 30 * 86_400 { return .soon }
        return .ok
    }
}

/// Kinds added later travel in `kindDetail`, with a kind every version knows in `kind`: an index or a
/// `.butakevault` written here still opens in an earlier Stack.
extension VaultItem {
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        container = try values.decode(UUID.self, forKey: .container)
        section = try values.decodeIfPresent(VaultSection.self, forKey: .section)
        let detail = try values.decodeIfPresent(String.self, forKey: .kindDetail).flatMap(VaultItemKind.init(rawValue:))
        kind = try detail ?? values.decode(VaultItemKind.self, forKey: .kind)
        name = try values.decode(String.self, forKey: .name)
        files = try values.decodeIfPresent([VaultFile].self, forKey: .files) ?? []
        fields = try values.decodeIfPresent([VaultField].self, forKey: .fields) ?? []
        notes = try values.decodeIfPresent(String.self, forKey: .notes) ?? ""
        environment = try values.decodeIfPresent(VaultEnvironment.self, forKey: .environment) ?? .none
        created = try values.decodeIfPresent(Date.self, forKey: .created) ?? Date()
        updated = try values.decodeIfPresent(Date.self, forKey: .updated) ?? Date()
        metadata = try values.decodeIfPresent(VaultMetadata.self, forKey: .metadata) ?? VaultMetadata()
        account = try values.decodeIfPresent(String.self, forKey: .account).flatMap(VaultNames.account)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(id, forKey: .id)
        try values.encode(container, forKey: .container)
        try values.encodeIfPresent(section, forKey: .section)
        try values.encode(kind.stored, forKey: .kind)
        if kind.stored != kind { try values.encode(kind.rawValue, forKey: .kindDetail) }
        try values.encode(name, forKey: .name)
        try values.encode(files, forKey: .files)
        try values.encode(fields, forKey: .fields)
        try values.encode(notes, forKey: .notes)
        try values.encode(environment, forKey: .environment)
        try values.encode(created, forKey: .created)
        try values.encode(updated, forKey: .updated)
        try values.encode(metadata, forKey: .metadata)
        try values.encodeIfPresent(account, forKey: .account)
    }
}

/// Name rules: names become folder and file names on export, so they are kept to safe characters.
enum VaultNames {
    static func isBundleId(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && value.count <= 155 && parts.allSatisfy { part in
            !part.isEmpty && part.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }
    /// One path component: no separators, no control characters, not "." or "..", not hidden.
    static func isSafeComponent(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 120, trimmed != ".", trimmed != "..", !trimmed.hasPrefix("..") else { return false }
        return !trimmed.unicodeScalars.contains { $0 == "/" || $0 == ":" || $0 == "\\" || CharacterSet.controlCharacters.contains($0) }
    }
    /// A file name kept as is when safe (".env" included), otherwise rebuilt from its safe characters.
    static func safeFileName(_ value: String) -> String {
        if isSafeComponent(value) { return value.trimmingCharacters(in: .whitespaces) }
        let cleaned = String(value.unicodeScalars.filter { !($0 == "/" || $0 == ":" || $0 == "\\" || CharacterSet.controlCharacters.contains($0)) }
            .map(Character.init)).trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return cleaned.isEmpty ? "archivo" : String(cleaned.prefix(120))
    }
    /// An account of a service: one to three safe components ("cuenta", "tunnels/principal"), or nil.
    static func account(_ value: String) -> String? {
        let parts = value.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard (1...3).contains(parts.count), parts.allSatisfy(isSafeComponent) else { return nil }
        return parts.joined(separator: "/")
    }
    /// A service path: one or two safe components ("cloudflare/cuenta").
    static func isServicePath(_ value: String) -> Bool {
        let parts = value.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        return (1...3).contains(parts.count) && parts.allSatisfy(isSafeComponent)
    }
}
