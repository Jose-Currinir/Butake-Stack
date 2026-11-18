import Foundation

/// A profile of AWS CLI as the engine reads it (engine/src/aws/profiles.rs). It never carries a
/// secret: of an access key only its last four characters.
struct AWSProfile: Decodable, Identifiable, Hashable, Sendable {
    enum Kind: String, Decodable, CaseIterable, Sendable {
        case `static`, sso, role, process, none
        var symbol: String {
            switch self {
            case .static: Symbols.key
            case .sso: Symbols.signIn
            case .role: Symbols.assumeRole
            case .process: Symbols.credentialProcess
            case .none: Symbols.awsProfile
            }
        }
        var title: String { L("aws.kind.\(rawValue)") }
    }
    struct Session: Decodable, Hashable, Sendable {
        let expiresAt: Double?
        let valid: Bool
        var expiry: Date? { expiresAt.map { Date(timeIntervalSince1970: $0) } }
    }
    struct ProjectUse: Decodable, Hashable, Sendable {
        let project: String
        let projectName: String
        let environment: String
        let environmentName: String
        let production: Bool
    }

    let name: String
    let isDefault: Bool
    let kind: Kind
    let region: String?
    let output: String?
    let account: String?
    let keySuffix: String?
    /// The file that keeps its access keys in plain text (`credentials` or `config`).
    let keyFile: String?
    let temporary: Bool
    let ssoSession: String?
    let ssoStartUrl: String?
    let ssoRegion: String?
    let roleName: String?
    let session: Session?
    let roleArn: String?
    let sourceProfile: String?
    let credentialSource: String?
    /// Stack's credential process: `ok`, `other` (another copy of Stack) or `missing`.
    let helper: String?
    let duplicated: Bool
    let projects: [ProjectUse]

    var id: String { name }
    /// Its keys are in the Keychain behind Stack's credential process.
    var inKeychain: Bool { helper != nil }
    var needsRepair: Bool { helper == "missing" || helper == "other" }
    var hasKeys: Bool { keyFile != nil || inKeychain }

    func matches(_ text: String) -> Bool {
        text.isEmpty || [name, account, region, roleArn, ssoSession].compactMap(\.self).contains { $0.localizedCaseInsensitiveContains(text) }
    }
}

struct AWSSSOSession: Decodable, Hashable, Sendable {
    let name: String
    let startUrl: String?
    let region: String?
}

/// `awsProfiles`: AWS CLI on this Mac, the two files and their profiles.
struct AWSState: Decodable, Sendable {
    struct CLI: Decodable, Sendable { let installed: Bool; let path: String?; let signInLimit: Int? }
    let cli: CLI
    let configPath: String
    let credentialsPath: String
    let profiles: [AWSProfile]
    let ssoSessions: [AWSSSOSession]
    let helperAvailable: Bool
}

/// What «Comprobar» found: who the profile is. Kept only while the app runs.
struct AWSIdentity: Decodable, Hashable, Sendable {
    let account: String
    let arn: String?
    let userId: String?
}

/// A profile as the sheet edits it (never its keys; they travel apart, once).
struct AWSDraft: Equatable {
    var name = ""
    var kind: AWSProfile.Kind = .static
    var region = ""
    var output = ""
    var ssoSession = ""
    var ssoStartUrl = ""
    var ssoRegion = ""
    var accountId = ""
    var roleName = ""
    var roleArn = ""
    var sourceProfile = ""

    init() {}
    init(_ profile: AWSProfile) {
        name = profile.name
        kind = profile.kind
        region = profile.region ?? ""
        output = profile.output ?? ""
        ssoSession = profile.ssoSession ?? ""
        accountId = profile.kind == .sso ? profile.account ?? "" : ""
        roleName = profile.roleName ?? ""
        roleArn = profile.roleArn ?? ""
        sourceProfile = profile.sourceProfile ?? ""
    }

    var json: [String: Any] {
        ["name": name, "kind": kind.rawValue, "region": region, "output": output, "ssoSession": ssoSession,
         "ssoStartUrl": ssoStartUrl, "ssoRegion": ssoRegion, "accountId": accountId, "roleName": roleName,
         "roleArn": roleArn, "sourceProfile": sourceProfile]
    }

    /// The names the engine accepts (letters, digits, dot, dash, underscore; starts with a letter
    /// or digit).
    static func validName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, (1...64).contains(name.count) else { return false }
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return CharacterSet.alphanumerics.contains(first) && first.isASCII && name.unicodeScalars.allSatisfy(allowed.contains)
    }
}
