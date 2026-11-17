#if DEBUG
import SwiftUI

/// The Terminal's consoles of this Mac in the QA window (the assistant is always a double in a
/// temporary home): BUTAKE_QA_TERMINAL=<program id>[,usage] opens that program in a tab and, with
/// «usage», the content of its consumption popover over the terminal (a popover is a window of its
/// own, which the snapshot of the main window does not draw).
@MainActor enum TerminalQA {
    private static var steps: [String] {
        guard StackStore.qaWindow, let value = ProcessInfo.processInfo.environment["BUTAKE_QA_TERMINAL"] else { return [] }
        return value.split(separator: ",").map(String.init)
    }
    static var showsUsage: Bool { steps.contains("usage") }

    /// The popover's content, as a card at the top of the session.
    @ViewBuilder static func usagePanel(_ workspace: SSHWorkspace) -> some View {
        if showsUsage, let session = workspace.current?.focusedSession, let source = AssistantUsageSource.of(session.kind.launch?.program) {
            AssistantUsagePanel(session: session, source: source)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10, style: .continuous)).padding(10)
        }
    }

    static func start(workspace: SSHWorkspace) async {
        guard let id = steps.first else { return }
        if StackStore.shared.devTools.isEmpty { await StackStore.shared.refreshDevTools() }
        if let program = LocalConsoles.program(id) { workspace.openLocal(program) }
    }
}
#endif
