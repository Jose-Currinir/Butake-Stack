import Foundation

/// Whether an app of the vault can be signed and published in a stage, crossing what it holds: for
/// Android the keystore, `google-services.json` of the right package, the Google Play service account and
/// the Firebase App ID; for iOS, per bundle (app, widget, watch), the profile and whether it includes a
/// certificate whose `.p12` is in the vault, the App Store Connect key and `GoogleService-Info.plist` of
/// the right bundle. Only names, kinds, dates and public fingerprints are used in what it says: never a
/// value. Items without a stage count for both stages.
enum VaultSigning {
    enum Status: Int, Comparable, CaseIterable, Hashable {
        case ready, expiring, missing, mismatch
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        /// The end of its texts' keys (`vault.signing.status.ready`…).
        var key: String { ["ready", "expiring", "missing", "mismatch"][rawValue] }
    }

    enum Platform: String, CaseIterable, Identifiable, Hashable {
        case android, ios
        var id: String { rawValue }
    }

    struct Row: Identifiable, Hashable {
        var id: String
        var platform: Platform
        var title: String
        var status: Status
        var detail: String
        var advice: String?
        /// The item it is about, opened from the row.
        var item: UUID?
        /// What to add when it is missing.
        var add: VaultItemKind?
    }

    /// The two stages an app is signed for.
    static let environments: [VaultEnvironment] = [.test, .prod]

    // MARK: Report

    static func rows(for app: VaultContainer, environment: VaultEnvironment, in index: VaultIndex, now: Date = Date()) -> [Row] {
        let context = Context(app: app, environment: environment, index: index, now: now)
        var rows: [Row] = []
        let platforms = context.platforms
        if platforms.contains(.android) { rows += context.androidRows() }
        if platforms.contains(.ios) { rows += context.iosRows() }
        return rows
    }

    /// «No calza: 1 · Listo: 5», worst first.
    static func summary(_ rows: [Row]) -> String {
        Status.allCases.reversed().compactMap { status -> String? in
            let count = rows.filter { $0.status == status }.count
            return count == 0 ? nil : String(format: L("vault.signing.count.\(status.key)"), count)
        }.joined(separator: " · ")
    }

    static func worst(_ rows: [Row]) -> Status? { rows.map(\.status).max() }

    /// What a profile allows that matters to publish, by its usual names.
    static func capabilities(_ entitlements: [String: Any]) -> [String] {
        var out: [String] = []
        if let groups = entitlements["com.apple.security.application-groups"] as? [String], !groups.isEmpty { out.append("App Groups (\(groups.count))") }
        if entitlements["com.apple.developer.healthkit"] as? Bool == true { out.append("HealthKit") }
        if let push = entitlements["aps-environment"] as? String { out.append(String(format: L("vault.signing.push"), push)) }
        if entitlements["com.apple.developer.applesignin"] != nil { out.append("Sign in with Apple") }
        return out
    }

    /// A bundle or package accepted for a stage: the app's own, and before production also its
    /// variants (`cl.demo.app.qa`).
    static func accepts(_ id: String, bundle: String, environment: VaultEnvironment) -> Bool {
        id == bundle || (environment != .prod && id.hasPrefix(bundle + "."))
    }

    /// «AB:CD:EF:01…89:AB»: enough to recognize a fingerprint without a whole line of it.
    static func short(_ fingerprint: String) -> String {
        fingerprint.count > 18 ? String(fingerprint.prefix(11)) + "…" + String(fingerprint.suffix(5)) : fingerprint
    }

    static func isFirebaseAppId(_ item: VaultItem) -> Bool {
        item.kind == .token && ([item.name] + item.fields.flatMap { [$0.label, $0.envVar ?? ""] }).contains { $0.dataCapitals.contains("FIREBASE_APP_ID") }
    }

    /// The bundle a profile signs: its App ID without the team in front.
    static func bundle(of profile: VaultItem) -> String? {
        guard let appId = profile.metadata.value("vault.meta.appId"), let dot = appId.firstIndex(of: ".") else { return nil }
        return String(appId[appId.index(after: dot)...])
    }

    // MARK: Crossing

    struct Context {
        let app: VaultContainer
        let environment: VaultEnvironment
        let index: VaultIndex
        let now: Date
        var items: [VaultItem] { index.items(in: app.id) }

        func current(_ item: VaultItem) -> Bool { item.environment == environment || item.environment == .none }
        func here(_ kind: VaultItemKind) -> [VaultItem] { items.filter { $0.kind == kind && current($0) } }
        /// Shared by every app: the items of the services that `matches` names.
        func shared(_ kind: VaultItemKind, _ matches: (String) -> Bool) -> [(VaultItem, String)] {
            index.containers.filter { $0.kind == .service && matches($0.name) }
                .flatMap { service in index.items(in: service.id).filter { $0.kind == kind }.map { ($0, service.name) } }
        }

        var usesFirebase: Bool {
            items.contains { [.googleServices, .googleServiceInfo].contains($0.kind) || VaultSigning.isFirebaseAppId($0) }
        }

        var platforms: [Platform] {
            let android = items.contains { $0.section == .android || [.androidKeystore, .googleServices].contains($0.kind) }
            let ios = items.contains { $0.section == .ios || [.iosCertificate, .provisioningProfile, .appStoreKey, .googleServiceInfo].contains($0.kind) }
            return android || ios ? Platform.allCases.filter { $0 == .android ? android : ios } : Platform.allCases
        }

        /// The state of a dated item: expired does not fit, within 30 days expires soon.
        func dated(_ item: VaultItem, ready: Status = .ready) -> Status {
            switch item.expiry(now: now) {
            case .expired?: .mismatch
            case .soon?: max(ready, .expiring)
            default: ready
            }
        }

        func expiryText(_ item: VaultItem) -> String? {
            item.metadata.expires.map { String(format: L(item.expiry(now: now) == .expired ? "vault.expiredOn" : "vault.expiresOn"), Format.shortDate($0)) }
        }

        func row(_ id: String, _ platform: Platform, _ title: String, _ status: Status, _ detail: String, advice: String? = nil,
                 item: UUID? = nil, add: VaultItemKind? = nil) -> Row {
            Row(id: "\(platform.rawValue).\(id)", platform: platform, title: title, status: status, detail: detail,
                advice: status == .ready ? nil : advice, item: item, add: status == .missing && item == nil ? add : nil)
        }

        /// A problem read from a file: a password still missing, or one that does not open it.
        func problemRow(_ id: String, _ platform: Platform, _ title: String, _ item: VaultItem) -> Row? {
            guard let problem = item.metadata.problem else { return nil }
            let missing = ["vault.meta.needsPassword", "vault.meta.noJava"].contains(problem)
            return row(id, platform, title, missing ? .missing : .mismatch, "\(item.name) · \(L(problem))",
                       advice: L(missing ? "vault.signing.advice.complete" : "vault.signing.advice.fix"), item: item.id)
        }
    }
}
