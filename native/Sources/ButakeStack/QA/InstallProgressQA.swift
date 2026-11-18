#if DEBUG
import Foundation

/// Screenshots of an install in progress, with made-up data (nothing is downloaded nor installed,
/// the engine is not asked): BUTAKE_QA_INSTALL_PHASE = download | build | done | failed |
/// cancelled, on the sheet BUTAKE_QA_UTILITY_SHEET opens, or on a version picker
/// (BUTAKE_QA_VERSION_PICKER=<language>).
extension QAHooks {
    static var installPhase: String? { StackStore.qaWindow ? ProcessInfo.processInfo.environment["BUTAKE_QA_INSTALL_PHASE"] : nil }

    static func installProgress(_ monitor: InstallMonitor) async {
        guard let phase = installPhase else { return }
        try? await Task.sleep(for: .seconds(2.5))
        show(phase, on: monitor)
    }

    static func show(_ phase: String, on monitor: InstallMonitor) {
        let git = monitor.tool == "git"
        // A toolchain through its official installer: one step, not cut (InstallMonitor.external).
        if monitor.tool.hasSuffix("-toolchain") {
            monitor.plan = ["toolchain"]
            monitor.started = Date().addingTimeInterval(-48)
            monitor.reported = monitor.plan
            monitor.fixed = phase != "done"
            monitor.lines = ["info: syncing channel updates for 'beta-aarch64-apple-darwin'", "info: downloading component 'rustc'",
                             "info: installing component 'rust-std'"]
            monitor.showLog = phase == "build"
            if phase == "done" { monitor.ended = Date() }
            monitor.phase = phase == "done" ? .done : .running
            return
        }
        monitor.plan = git ? ["downloadSource", "verifySum", "build", "install", "link"] : ["download", "verifySum", "install"]
        monitor.started = Date().addingTimeInterval(phase == "download" ? -14 : -312)
        monitor.lines = git ? [
            "$ make -j8 prefix=~/.local/share/butake-stack/git/2.56.1 install",
            "    CC daemon.o", "    CC fsck.o", "    CC builtin/add.o", "    CC builtin/am.o", "    CC builtin/blame.o",
            "    CC builtin/branch.o", "    CC builtin/checkout.o", "    LINK git-daemon", "    CC builtin/commit.o",
        ] : ["descargando node-v24.11.1-darwin-arm64.tar.gz"]
        switch phase {
        case "download":
            monitor.reported = [monitor.plan[0]]
            monitor.bytes = (done: 4_718_592, total: 11_534_336)
            monitor.lines = []
            monitor.phase = .running
        case "build":
            monitor.reported = Array(monitor.plan.prefix(3))
            monitor.showLog = true
            monitor.phase = .running
        case "done":
            monitor.reported = monitor.plan
            monitor.ended = Date()
            monitor.phase = .done
        case "failed":
            monitor.reported = Array(monitor.plan.prefix(git ? 3 : 1))
            monitor.lines.append(git ? "make: *** [builtin/commit.o] Error 1" : "curl: (22) The requested URL returned error: 404")
            monitor.ended = Date()
            monitor.phase = .failed(L(git ? "error.build_failed" : "error.download_failed"))
        default:
            monitor.reported = Array(monitor.plan.prefix(git ? 3 : 1))
            monitor.ended = Date()
            monitor.phase = .cancelled
        }
    }
}
#endif
