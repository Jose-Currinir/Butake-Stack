import Foundation

/// The folders of a real keys backup, besides Stack's own (`android/`, `ios/`…):
///
///     <app> (<bundle>)/{01-API,02-WEB,03-IOS,04-ANDROID,05-TERCEROS}/{QA,PROD}/…
///     <app> (<bundle>)/99-HISTORICO-TRANSICION/…   history: not imported by default
///     …/_CUARENTENA-…/…                            quarantine: never imported nor read
///     …/_archive/…, …/backups/…                     archives: not imported by default
///     _SERVICIOS/{apple-signing,apple-appstore,apple-apns,google-play,gcp}/…
///
/// Only names are read here; what a file holds is read by `VaultCompanions` while importing.
enum VaultBackupLayout {
    /// Why a file is listed unselected: it is history, an archive, a backup, a database dump or kept in
    /// quarantine (`_CUARENTENA…`).
    enum Exclusion: String, CaseIterable, Hashable, Sendable {
        case history, archive, backups, dump, quarantine
        /// Dumps hold personal data and a quarantine sensitive material: their content is never read
        /// (not even to tell their kind) and the preview does not offer to import them.
        var isSealed: Bool { self == .dump || self == .quarantine }
    }

    /// The part of the app a folder stands for: «03-IOS», «04-ANDROID», «01-API», «02-WEB», «05-TERCEROS»
    /// and Stack's own `android`, `ios`, `server`, `terceros`.
    static func section(forFolder name: String) -> VaultSection? {
        switch platformName(name) {
        case "android": .android
        case "ios", "apple": .ios
        case "api", "web", "server", "servidor", "backend": .server
        case "terceros", "third-party", "thirdparty": .terceros
        default: nil
        }
    }

    /// `QA` and its kin are «Preproducción»; `PROD`, «Producción».
    static func environment(forFolder name: String) -> VaultEnvironment? {
        switch name.trimmingCharacters(in: .whitespaces).lowercased() {
        case "qa", "staging", "test", "testing", "preprod", "preproduccion", "preproducción", "dev", "desarrollo": .test
        case "prod", "production", "produccion", "producción": .prod
        default: nil
        }
    }

    /// The number in front of a platform folder («03-IOS» → «ios») is dropped.
    static func platformName(_ name: String) -> String {
        let lower = name.trimmingCharacters(in: .whitespaces).lowercased()
        if let match = lower.firstMatch(of: /^[0-9]{1,3}[-_ ](.+)$/) { return String(match.1) }
        return lower
    }

    static func excluded(folder name: String) -> Exclusion? {
        let lower = platformName(name)
        if ["_cuarentena", "cuarentena", "_quarantine", "quarantine"].contains(where: lower.hasPrefix) { return .quarantine }
        if lower.hasPrefix("historico") || lower.hasPrefix("histórico") || lower.hasPrefix("history") { return .history }
        if ["_archive", "archive", "archived", "archivo", "archivados", "_old"].contains(lower) { return .archive }
        if ["backups", "backup", "respaldos", "respaldo"].contains(lower) { return .backups }
        return nil
    }

    static func excluded(file name: String) -> Exclusion? {
        let lower = name.lowercased()
        // A dump's checksum (`base.dump.gz.sha256`) goes with its dump.
        for check in [".sha256", ".sha256sum", ".md5"] where lower.hasSuffix(check) {
            return excluded(file: String(lower.dropLast(check.count)))
        }
        let dumps = [".dump", ".sql", ".gz", ".tgz", ".contenido.txt", ".bak"]
        return dumps.contains(where: lower.hasSuffix) ? .dump : nil
    }

    /// A `.p8` under an APNs folder (`_SERVICIOS/apple-apns`, `…/push/…`) sends notifications.
    static func isPushFolder(_ components: [String]) -> Bool {
        components.contains { component in
            let lower = component.lowercased()
            return lower.contains("apns") || lower.contains("push")
        }
    }

    /// A Google Play service, shared by every app (`_SERVICIOS/google-play`).
    static func isPlayService(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("google-play") || lower.contains("googleplay") || lower.hasPrefix("play")
    }

    /// An App Store Connect service (`_SERVICIOS/apple-appstore`).
    static func isAppStoreService(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower.contains("appstore") || lower.contains("app-store") || lower.contains("asc")
    }

    // MARK: Download in the same layout

    /// The folder of a part when the backup layout is written back.
    static func platformFolder(_ section: VaultSection) -> String {
        switch section {
        case .server: "01-API"
        case .ios: "03-IOS"
        case .android: "04-ANDROID"
        case .terceros: "05-TERCEROS"
        }
    }

    static func environmentFolder(_ environment: VaultEnvironment) -> String? {
        switch environment {
        case .none: nil
        case .test: "QA"
        case .prod: "PROD"
        }
    }
}
