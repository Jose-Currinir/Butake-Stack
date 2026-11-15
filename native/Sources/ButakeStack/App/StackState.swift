import SwiftUI

/// What Stack is doing, said once per screen: the indicator of the status bar (and of the menu bar
/// panel) is its only source; Inicio repeats it only when there is something to do.
enum StackState: String, CaseIterable {
    /// Something essential is missing (Caddy, starting with the session, PHP, local trust).
    case setup
    /// The supervisor is not running: no project is served.
    case stopped
    /// Running, with a process that crashed or the web server without its ports.
    case attention
    case running

    var title: String { L("stackState.\(rawValue)") }
    @MainActor var color: Color {
        switch self {
        case .running: Brand.success
        case .stopped: Brand.danger
        case .setup, .attention: Brand.warning
        }
    }
    /// Inicio shows its header only when the user has something to do.
    var needsAction: Bool { self == .setup || self == .stopped }
}

extension StackStore {
    var stackState: StackState {
        if !setupComplete { return .setup }
        if !daemonRunning { return .stopped }
        return health == .green ? .running : .attention
    }
}

/// The colored dot and the short text; a click opens «Estado». The status bar and the menu bar
/// panel show this same control.
struct StackStateIndicator: View {
    @Bindable var store: StackStore
    @State private var showing = false
    var body: some View {
        let state = store.stackState
        Button { showing.toggle() } label: {
            Label {
                Text(state.title).lineLimit(1)
            } icon: {
                Circle().fill(state.color).frame(width: 8, height: 8)
            }
        }
        .buttonStyle(.accessoryBar)
        .help(L("stackState.help"))
        .accessibilityLabel(L("stackState.title"))
        .accessibilityValue(state.title)
        .accessibilityIdentifier("status.state")
        .popover(isPresented: $showing, arrowEdge: .top) {
            StackStatePopover(store: store)
        }
        #if DEBUG
        .task { if await QAHooks.opensStatePopover() { showing = true } }
        #endif
    }
}

/// «Estado»: the supervisor with its action, what runs and who holds the ports projects are served on.
struct StackStatePopover: View {
    @Bindable var store: StackStore
    var body: some View {
        Form {
            Section {
                LabeledContent {
                    HStack(spacing: 8) {
                        Text(store.daemonRunning ? L("state.running") : L("state.stopped")).foregroundStyle(.secondary)
                        if store.daemonRunning {
                            Button { Task { await store.reloadStack() } } label: { Label(L("stackState.restart"), systemImage: Symbols.reload) }
                                .buttonStyle(.bordered)
                                .help(L("menu.restartAll"))
                                .accessibilityIdentifier("state.restart")
                        } else {
                            Button { Task { await store.startDaemon() } } label: { Label(L("stackState.start"), systemImage: Symbols.start) }
                                .buttonStyle(.borderedProminent)
                                .accessibilityIdentifier("state.start")
                        }
                    }
                    .disabled(store.busy != nil)
                } label: {
                    Label { Text(L("stackState.supervisor")) } icon: { IconTile(symbol: Symbols.server, size: 22) }
                }
                LabeledContent {
                    Text(store.agent?.loaded == true ? L("stackState.on") : L("stackState.off")).foregroundStyle(.secondary)
                } label: {
                    Label { Text(L("activation.title")) } icon: { IconTile(symbol: Symbols.startup, size: 22) }
                }
            }
            Section {
                LabeledContent {
                    Text(String(format: L("stackState.count"), store.runningEngines, store.engineCount)).monospacedDigit()
                } label: {
                    Label { Text(L("stackState.services")) } icon: { IconTile(symbol: Symbols.service, size: 22) }
                }
                LabeledContent {
                    Text("\(store.runningSiteProcesses)").monospacedDigit()
                } label: {
                    Label { Text(L("stackState.processes")) } icon: { IconTile(symbol: Symbols.processes, size: 22) }
                }
            }
            Section(L("stackState.ports")) {
                ForEach([("53", store.ports?.dns), ("80", store.ports?.http), ("443", store.ports?.https)], id: \.0) { port, owner in
                    LabeledContent(String(format: L("stackState.port"), port)) {
                        Text(owner ?? L("stackState.portFree")).lineLimit(1).truncationMode(.middle).help(owner ?? "")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: TextScale.points(380))
        .fixedSize(horizontal: false, vertical: true) // lint-ui: popover that takes the height of its form
        .scaledText()
        .themedTint()
        .accessibilityIdentifier("state.popover")
        .task { await store.refreshPorts() }
    }
}
