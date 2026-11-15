import SwiftUI

/// Follows an install the engine runs (a utility, a version of a language or a service): its plan
/// (`installSteps`), where it is (`installProgress`: steps, download, output) and how it ended.
/// «Cancelar» stops it for real: the call is stoppable, so its engine and what it started end, and
/// the engine removes what was half done.
@MainActor @Observable final class InstallMonitor {
    enum Phase: Equatable {
        case ready, running, done, failed(String), cancelled
    }

    /// The engine's log of this install (`devtool-<tool>`, `install-<tool>`, `install-python`).
    let log: String
    let tool: String
    var plan: [String] = []
    var phase: Phase = .ready
    /// Steps the engine started, in order.
    var reported: [String] = []
    /// The current step places what was checked: it finishes, it is not stopped.
    var fixed = false
    var bytes: (done: Int64, total: Int64?)?
    var lines: [String] = []
    var started: Date?
    var ended: Date?
    var showLog = false
    @ObservationIgnored private var work: Task<Void, Never>?
    @ObservationIgnored private var store: StackStore?

    /// Steps of an official installer (rustup, swiftly, sdkmanager): they run to the end, because a
    /// cut would leave the installer's own folders half done (engine/src/runtimes/utilities/devtools/mod.rs).
    static let external: Set<String> = ["runInstaller", "updateToolchain", "toolchain", "licenses", "platformTools"]

    init(log: String, tool: String) {
        self.log = log
        self.tool = tool
    }

    var running: Bool { phase == .running }
    var finished: Bool { phase != .ready && phase != .running }
    /// The step under way (the plan's first until the engine reports one).
    var underWay: String? { reported.last ?? plan.first }
    var canCancel: Bool { running && !fixed && !Self.external.contains(underWay ?? "") }
    /// Why «Cancelar» is off while it runs.
    var cancelHelp: String {
        guard running, !canCancel else { return "" }
        return L(Self.external.contains(underWay ?? "") ? "progress.cantCancelExternal" : "progress.cantCancel")
    }
    /// Index of the current step in the plan (all done: the plan's length).
    var current: Int {
        if phase == .done { return plan.count }
        guard let last = reported.last, let index = plan.firstIndex(of: last) else { return 0 }
        return index
    }
    var steps: [ProgressStep] { plan.map { ProgressStep(id: $0, title: L("progress.step.\($0)")) } }
    var currentTitle: String? { plan.indices.contains(current) ? L("progress.step.\(plan[current])") : nil }
    /// A download with a known size: how much is done.
    var fraction: Double? {
        guard let bytes, let total = bytes.total, total > 0, reported.last?.hasPrefix("download") == true else { return nil }
        return min(1, Double(bytes.done) / Double(total))
    }
    var bytesText: String? {
        guard let bytes, let total = bytes.total, let fraction else { return nil }
        return String(format: L("progress.bytes"), Format.fileSizeText(bytes.done), Format.fileSizeText(total), Int(fraction * 100))
    }
    var elapsed: TimeInterval { (ended ?? Date()).timeIntervalSince(started ?? Date()) }

    /// Starts `work` (a stoppable engine call) and follows the log until it ends.
    func start(_ store: StackStore, _ work: @escaping @MainActor () async throws -> Void) {
        guard !running else { return }
        self.store = store
        phase = .running
        started = Date()
        ended = nil
        reported = []
        lines = []
        bytes = nil
        fixed = false
        self.work = Task {
            if let plan: [String] = try? await store.call(["method": "installSteps", "tool": tool]) { self.plan = plan }
            let follower = Task { while !Task.isCancelled { await self.refresh(store); try? await Task.sleep(for: .milliseconds(500)) } }
            do {
                try await work()
                phase = .done
            } catch where Self.cancelled(error) {
                phase = .cancelled
            } catch {
                phase = .failed(EngineFailure.message(error))
            }
            follower.cancel()
            await refresh(store)
            ended = Date()
        }
    }

    /// The same, waiting until it ends: true when it installed.
    func run(_ store: StackStore, _ work: @escaping @MainActor () async throws -> Void) async -> Bool {
        start(store, work)
        await self.work?.value
        return phase == .done
    }

    /// Stops the install: the engine ends what it started and removes what was half done. Where
    /// it is is read again first: a step that started meanwhile and cannot be cut runs to the end.
    func cancel() {
        guard canCancel else { return }
        Task {
            if let store { await refresh(store) }
            if canCancel { work?.cancel() }
        }
    }

    func refresh(_ store: StackStore) async {
        guard let state: InstallProgress = try? await store.call(["method": "installProgress", "name": log]) else { return }
        apply(state)
    }

    func apply(_ state: InstallProgress) {
        if reported != state.steps { reported = state.steps }
        if fixed != state.fixed { fixed = state.fixed }
        let next = state.bytes.flatMap { b in b.done.map { (done: $0, total: b.total) } }
        if next?.done != bytes?.done || next?.total != bytes?.total { bytes = next }
        if lines != state.lines { lines = state.lines }
    }

    nonisolated static func cancelled(_ error: Error) -> Bool {
        error is CancellationError || (error as? EngineFailure)?.code == "install_cancelled"
    }
}

extension SheetFrame {
    /// A sheet that follows `monitor`: «Cancelar» stops the install while it can (and says why
    /// not when it cannot), and the sheet does not close while it runs.
    func following(_ monitor: InstallMonitor?) -> some View {
        let running = monitor?.running == true
        return cancelling(running ? { monitor?.cancel() } : nil, enabled: !running || monitor?.canCancel == true,
                          help: monitor?.cancelHelp ?? "")
            .interactiveDismissDisabled(running)
    }
}

/// `installProgress`: the engine's reading of an install's log (engine/src/core/progress.rs).
struct InstallProgress: Decodable, Sendable {
    struct Bytes: Decodable, Sendable { let done: Int64?; let total: Int64? }
    let steps: [String]
    let fixed: Bool
    let bytes: Bytes?
    let lines: [String]
}

/// An install as the user follows it: elapsed time, its steps, how it ended and its output.
struct InstallProgressView: View {
    @Bindable var monitor: InstallMonitor
    /// «Git 2.56.1» or «Node.js 24.1.0»: what is installed.
    let name: String
    /// Identifier prefix: `<área>.progress`.
    let scope: String

    var body: some View {
        ScrollViewReader { proxy in
            Form {
                Section { status }
                if !monitor.plan.isEmpty {
                    StepListSection(steps: monitor.steps, current: monitor.current,
                                    stopped: monitor.phase == .cancelled || { if case .failed = monitor.phase { true } else { false } }(),
                                    fraction: monitor.running ? monitor.fraction : nil, detail: monitor.bytesText, scope: "\(scope).step")
                }
                if !monitor.lines.isEmpty {
                    Section { LogDisclosure(lines: monitor.lines, expanded: $monitor.showLog, id: "\(scope).log") }
                        .id("log")
                }
            }
            .formStyle(.grouped).themedScroll()
            // The detail, once opened, comes into view.
            .onChange(of: monitor.showLog, initial: true) { _, shown in
                if shown { Task { try? await Task.sleep(for: .milliseconds(200)); proxy.scrollTo("log", anchor: .bottom) } }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch monitor.phase {
        case .ready, .running:
            TimelineView(.periodic(from: monitor.started ?? Date(), by: 1)) { _ in
                LabeledContent(String(format: L("progress.installing"), name)) {
                    Text(Elapsed.clock(monitor.elapsed)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .accessibilityIdentifier("\(scope).running")
        case .done:
            Notice(.success, String(format: L("progress.done"), name), detail: String(format: L("progress.doneDetail"), Elapsed.clock(monitor.elapsed)))
                .accessibilityIdentifier("\(scope).done")
        case .failed(let message):
            Notice(.error, String(format: L("progress.failedAt"), monitor.currentTitle ?? name), detail: message)
                .accessibilityIdentifier("\(scope).failed")
        case .cancelled:
            Notice(.warning, L("progress.cancelled"), detail: L("progress.cancelledDetail"))
                .accessibilityIdentifier("\(scope).cancelled")
        }
    }
}

/// An install followed inside a longer list (restoring a configuration): which of its steps runs,
/// the download measured when its size is known, and its output under «Ver detalle».
struct InstallStepLine: View {
    @Bindable var monitor: InstallMonitor
    /// Identifier prefix: `<área>.progress`.
    let scope: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = monitor.currentTitle, !monitor.plan.isEmpty {
                Text(String(format: L("progress.stepOf"), min(monitor.current + 1, monitor.plan.count), monitor.plan.count, title))
                    .font(.uiCaption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(scope).step")
            }
            if let fraction = monitor.fraction {
                ProgressView(value: fraction).accessibilityIdentifier("\(scope).bar")
                if let bytes = monitor.bytesText { Text(bytes).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary) }
            }
            if !monitor.lines.isEmpty { LogDisclosure(lines: monitor.lines, expanded: $monitor.showLog, id: "\(scope).log") }
        }
    }
}
