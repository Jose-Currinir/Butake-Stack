import AppKit
import SwiftUI

/// What moving the data would do (`migrateDataPlan`); nothing changes until the user confirms.
struct DataMigrationPlan: Decodable, Sendable {
    struct Rewrite: Decodable, Sendable, Hashable { let path: String; let kind: String; let place: String }
    let state: String
    let from: String
    let to: String
    var bytes: Int64?
    var files: Int?
    var free: Int64?
    var sameVolume: Bool?
    var enoughSpace: Bool?
    var running: [String]?
    var backup: String?
    var rewrites: [Rewrite]?
    var seconds: Int?
}

/// How a run ended (`migrateData`): on failure, the step, the code and whether everything went back.
struct DataMigrationResult: Decodable, Sendable {
    struct Check: Decodable, Sendable, Hashable { let id: String; var running: Bool?; var answers: Bool? }
    let ok: Bool
    var already: Bool?
    var step: String?
    var error: String?
    var detail: String?
    var reverted: Bool?
    var backup: String?
    var rewritten: [String]?
    var report: [Check]?
}

/// Ajustes › Avanzado › «Mover los datos a la carpeta Stack…»: the plan (size, what stops, which
/// paths are rewritten, where the backup goes), a destructive confirmation, the run and its report.
struct DataMigrationSheet: View {
    @Bindable var store: StackStore
    @State private var plan: DataMigrationPlan?
    @State private var failure: String?
    @State private var result: DataMigrationResult?
    @State private var moving = false
    @State private var confirming = false
    @Environment(\.dismiss) private var dismiss

    /// Codes a run can end with (`engine/src/app/migrate`), each with its text (`migration.error.*`).
    static let errorCodes = ["migration_files_open", "migration_unclean_shutdown", "migration_daemon_running", "migration_backup_failed",
                             "migration_start_failed", "migration_rewrite_failed", "migration_revert_failed", "migration_failed"]
    /// Where a rewritten path lives (`migration.place.*`).
    static let places = ["data", "launchAgent", "terminal", "aws", "links", "project"]

    var body: some View {
        SheetFrame(title: L("migration.title"), symbol: Symbols.importing, detail: L("migration.detail"),
                   note: result == nil ? L("migration.note") : nil, width: 620, height: 600,
                   actionTitle: actionTitle, actionSymbol: result?.ok == true && result?.already != true ? Symbols.reload : nil,
                   actionID: "migration.action", canAct: canAct, cancelID: result == nil ? "migration.cancel" : nil) {
            await act()
        } content: {
            Form { content }
                .formStyle(.grouped).themedScroll()
        }
        .interactiveDismissDisabled(moving)
        .task { await load() }
        .confirmationDialog(L("migration.confirm"), isPresented: $confirming, titleVisibility: .visible) {
            Button(L("migration.confirmAction"), role: .destructive) { Task { await move() } }
            Button(L("common.cancel"), role: .cancel) {}
        } message: {
            Text(L("migration.confirmDetail"))
        }
    }

    private var actionTitle: String {
        guard let result else { return L("migration.action") }
        return result.ok && result.already != true ? L("migration.restart") : L("common.done")
    }
    private var canAct: Bool {
        if moving { return false }
        if result != nil { return true }
        return plan?.state == "resume" || (plan?.state == "ready" && plan?.enoughSpace == true && plan?.sameVolume == true)
    }

    /// The action button: the confirmation first; after a run, restart (or close).
    private func act() async -> Bool {
        guard let result else { confirming = true; return false }
        if result.ok && result.already != true { Self.relaunch() }
        return true
    }

    @ViewBuilder private var content: some View {
        if moving {
            Section { LabeledContent(L("migration.moving")) { ProgressView().controlSize(.small) } }
        } else if let result {
            resultSections(result)
        } else if let failure {
            Section { Notice(.error, failure) }
        } else if let plan {
            planSections(plan)
        } else {
            Section { LabeledContent(L("migration.loading")) { ProgressView().controlSize(.small) } }
        }
    }

    @ViewBuilder private func planSections(_ plan: DataMigrationPlan) -> some View {
        if plan.state != "ready" {
            Section { Notice(plan.state == "conflict" ? .warning : .info, L("migration.state.\(plan.state)")) }
        }
        Section(L("migration.what")) {
            path(L("migration.from"), plan.from)
            path(L("migration.to"), plan.to)
            if let bytes = plan.bytes {
                LabeledContent(L("migration.size"), value: String(format: L("migration.sizeValue"), Format.fileSizeText(bytes), plan.files ?? 0))
            }
            if let free = plan.free {
                LabeledContent(L("migration.free"), value: Format.fileSizeText(free))
            }
            if let seconds = plan.seconds {
                let minutes = (seconds + 59) / 60
                LabeledContent(L("migration.time"), value: minutes <= 1 ? L("migration.timeMinute") : String(format: L("migration.timeValue"), minutes))
            }
        }
        if plan.enoughSpace == false { Section { Notice(.error, L("migration.noSpace")) } }
        if plan.sameVolume == false { Section { Notice(.error, L("migration.otherVolume")) } }
        if let running = plan.running {
            Section(L("migration.stops")) {
                if running.isEmpty { Text(L("migration.nothingRunning")).foregroundStyle(.secondary) }
                ForEach(running, id: \.self) { Text(Self.processName($0)) }
            }
        }
        if let rewrites = plan.rewrites {
            Section(String(format: L("migration.rewrites"), rewrites.count)) {
                ForEach(rewrites, id: \.self) { rewrite in
                    LabeledContent(L("migration.place.\(rewrite.place)")) {
                        Text(Self.short(rewrite.path)).lineLimit(1).truncationMode(.middle).help(rewrite.path).foregroundStyle(.secondary)
                    }
                }
            }
        }
        if let backup = plan.backup {
            Section {
                path(L("migration.backup"), backup)
            } footer: {
                SettingsFooter(L("migration.backupFooter"))
            }
        }
    }

    @ViewBuilder private func resultSections(_ result: DataMigrationResult) -> some View {
        Section {
            if result.ok {
                Notice(.info, L(result.already == true ? "migration.already" : "migration.done"), symbol: Symbols.success)
            } else {
                let code = result.error ?? "migration_failed"
                let text = L("migration.error.\(Self.errorCodes.contains(code) ? code : "migration_failed")")
                Notice(.error, text, detail: result.detail)
                Text(L(result.reverted == true ? "migration.reverted" : "migration.notReverted")).foregroundStyle(.secondary)
            }
        }
        if let report = result.report, !report.isEmpty {
            Section(L("migration.checks")) {
                ForEach(report, id: \.self) { check in
                    LabeledContent(Self.processName(check.id)) {
                        Label(L(check.answers == true ? "migration.answers" : "migration.noAnswer"),
                              systemImage: check.answers == true ? Symbols.success : Symbols.warning)
                            .foregroundStyle(check.answers == true ? Brand.success : Brand.warning)
                    }
                }
            }
        }
        if let backup = result.backup { Section { path(L("migration.backup"), backup) } }
    }

    private func path(_ title: String, _ value: String) -> some View {
        LabeledContent(title) {
            Text(Self.short(value)).lineLimit(1).truncationMode(.middle).help(value).foregroundStyle(.secondary)
        }
    }

    // MARK: Work

    private func load() async {
        #if DEBUG
        if QAHooks.dataMigrationResult { result = DataMigrationResult(ok: true, backup: Folder.base, report: [.init(id: "stack.mysql", running: true, answers: true)]); return }
        #endif
        do { plan = try await store.engine.call(["method": "migrateDataPlan"]) } catch { failure = error.localizedDescription }
    }

    private func move() async {
        moving = true
        store.pauseForDataMove()
        // Database sessions keep their sockets in the folder: they close first, as when the app quits.
        await Task.detached { DatabaseClient.disconnectAllNow() }.value
        do { result = try await store.engine.call(["method": "migrateData", "confirmed": true]) } catch { failure = error.localizedDescription }
        moving = false
        if result?.ok != true { store.startPolling() }
    }

    /// The same app again, on the moved data: every path it holds in memory is the old one.
    static func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    static func short(_ path: String) -> String { path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }

    /// A supervised process by name: services, PHP-FPM by version, Caddy, a project's process.
    static func processName(_ id: String) -> String {
        guard id.hasPrefix("stack.") else { return id }
        let part = String(id.dropFirst("stack.".count))
        if part.hasPrefix("php-") { return "PHP-FPM " + part.dropFirst(4).replacingOccurrences(of: "-", with: ".") }
        return Tech.of(part).title
    }
}
