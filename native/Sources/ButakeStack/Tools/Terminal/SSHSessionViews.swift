import AppKit
import SwiftTerm
import SwiftUI

// MARK: - Tab bar

/// One tab per terminal or file browser (none is selected while the host's card is shown). Each tab
/// is a button with its own close button; ⌘T opens one, ⌘W closes it and ⌃Tab moves between them.
struct WorkspaceTabBar: View {
    @Bindable var workspace: SSHWorkspace
    var body: some View {
        HStack(spacing: 0) {
            tabs
            // How the assistant of the session shown is doing, when it is one.
            if let session = workspace.current?.focusedSession, let source = AssistantUsageSource.of(session.kind.launch?.program) {
                AssistantUsageButton(session: session, source: source).padding(.horizontal, 10).id(session.id)
            }
        }
        .overlay(alignment: .bottom) { Divider() }
        .accessibilityIdentifier("ssh.tabs")
    }

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(Array(workspace.tabs.enumerated()), id: \.element.id) { index, tab in
                    SSHTabButton(title: tab.title, symbol: tab.symbol, help: tab.focusedSession?.programTitle ?? tab.title,
                                 selected: workspace.selected == tab.id, ended: tab.ended, id: "ssh.tabs.\(index)",
                                 close: { workspace.requestClose(tab) }) {
                        // The list follows the tab by itself (`listSelection`); what was chosen by hand stays.
                        workspace.selected = tab.id
                        tab.focusedSession?.focus()
                    }
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
        }
    }
}

private struct SSHTabButton: View {
    let title: String
    let symbol: String
    let help: String
    let selected: Bool
    let ended: Bool
    let id: String
    let close: (() -> Void)?
    let select: () -> Void
    var body: some View {
        HStack(spacing: 2) {
            Button(action: select) {
                Label {
                    Text(title).lineLimit(1).truncationMode(.tail).frame(maxWidth: 180, alignment: .leading)
                } icon: {
                    Image(systemName: ended ? Symbols.warning : symbol).foregroundStyle(ended ? Brand.warning : .secondary)
                }
                .font(.uiCallout.weight(selected ? .semibold : .regular))
            }
            .buttonStyle(.borderless)
            .help(ended ? L("ssh.tabs.ended") : help)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier(id)
            if let close {
                Button(action: close) { Label(L("ssh.terminal.closeTab"), systemImage: Symbols.close).labelStyle(.iconOnly).font(.uiCaption) }
                    .buttonStyle(.borderless)
                    .help(L("ssh.terminal.closeTab")).accessibilityIdentifier("\(id).close")
            }
        }
        .padding(.leading, 9).padding(.trailing, close == nil ? 9 : 5).padding(.vertical, 4)
        .background(selected ? Color.primary.opacity(0.1) : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .accessibilityElement(children: .contain)
    }
}

// MARK: - A terminal tab

/// A terminal tab: its panes, side by side or stacked. Its actions (search, snippets, split, theme)
/// are in the window's toolbar.
struct TerminalTabView: View {
    @Bindable var tab: WorkspaceTab
    @Bindable var workspace = SSHWorkspace.shared
    @Bindable var text = TextScale.shared
    var body: some View {
        if let root = tab.root {
            PaneView(node: root, tab: tab, theme: workspace.theme, scale: text.factor)
        }
    }
}

/// A tab's layout, recursively: terminals side by side or stacked, resizable.
private struct PaneView: View {
    let node: PaneNode
    let tab: WorkspaceTab
    let theme: TerminalTheme
    let scale: Double
    var body: some View {
        switch node {
        case .leaf(let session):
            TerminalPaneView(session: session, tab: tab, theme: theme, scale: scale)
        case .split(let axis, let children):
            if axis == .horizontal {
                HSplitView { ForEach(children) { child in PaneView(node: child, tab: tab, theme: theme, scale: scale).frame(minWidth: 160) } }
            } else {
                VSplitView { ForEach(children) { child in PaneView(node: child, tab: tab, theme: theme, scale: scale).frame(minHeight: 90) } }
            }
        }
    }
}

private struct TerminalPaneView: View {
    @Bindable var session: TerminalSession
    @Bindable var tab: WorkspaceTab
    let theme: TerminalTheme
    let scale: Double
    @FocusState private var searchFocused: Bool
    var body: some View {
        let focused = tab.focused == session.id && tab.sessions.count > 1
        VStack(spacing: 0) {
            if session.searchVisible {
                HStack(spacing: 8) {
                    TextField(L("ssh.terminal.searchPlaceholder"), text: $session.searchText)
                        .textFieldStyle(.roundedBorder).focused($searchFocused)
                        .onSubmit { session.find(next: true) }
                        .accessibilityIdentifier("ssh.terminal.searchField")
                    Text(session.matchSummary).font(.uiCaption).foregroundStyle(.secondary).fixedSize()
                    ControlGroup {
                        Button { session.find(next: false) } label: { Label(L("ssh.terminal.searchPrevious"), systemImage: Symbols.back) }
                            .help(L("ssh.terminal.searchPrevious")).accessibilityIdentifier("ssh.terminal.searchPrevious")
                        Button { session.find(next: true) } label: { Label(L("ssh.terminal.searchNext"), systemImage: Symbols.forward) }
                            .help(L("ssh.terminal.searchNext")).accessibilityIdentifier("ssh.terminal.searchNext")
                    }
                    .labelStyle(.iconOnly).fixedSize()
                    Button { session.closeSearch() } label: { Label(L("common.done"), systemImage: Symbols.close) }
                        .buttonStyle(.bordered).keyboardShortcut(.cancelAction)
                        .help(L("ssh.terminal.searchClose")).accessibilityIdentifier("ssh.terminal.searchClose")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .overlay(alignment: .bottom) { Divider() }
                .onAppear { searchFocused = true }
            }
            ZStack {
                TerminalHost(session: session, theme: theme, scale: scale)
                if !session.running, let code = session.exitCode {
                    let local = session.kind.isLocal
                    VStack(spacing: 10) {
                        Image(systemName: code == 0 ? Symbols.success : Symbols.disconnect).font(.uiLargeTitle)
                            .foregroundStyle(code == 0 ? Brand.success : Brand.warning)
                        Text(local ? L("ssh.local.ended") : code == 0 ? L("ssh.terminal.ended") : String(format: L("ssh.terminal.dropped"), code))
                            .font(.uiHeadline)
                            .help(local && code != 0 ? String(format: L("ssh.local.exitCode"), code) : "")
                        HStack {
                            Button { SSHWorkspace.shared.requestClosePane(tab, session) } label: { Label(L("ssh.terminal.closePane"), systemImage: Symbols.close) }
                                .buttonStyle(.bordered).accessibilityIdentifier("ssh.terminal.closeEnded")
                            Button { Task { await session.reconnect() } } label: {
                                Label(L(local ? "ssh.local.reopen" : "ssh.terminal.reconnect"), systemImage: Symbols.reload)
                            }
                            .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                            .accessibilityIdentifier(local ? "ssh.local.reopen" : "ssh.terminal.reconnect")
                        }
                    }
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 24)
                }
            }
        }
        .overlay { if focused { Rectangle().strokeBorder(Color.accentColor.opacity(0.55), lineWidth: 1.5).allowsHitTesting(false) } }
    }
}

/// Hosts a session's SwiftTerm view; the same view moves between containers when the layout
/// changes, so the screen and scrollback are never lost. The text keeps a terminal's inner margin
/// from the pane's edges, filled with the theme's background.
private struct TerminalHost: NSViewRepresentable {
    let session: TerminalSession
    let theme: TerminalTheme
    let scale: Double
    /// The inner margin of a terminal window, between its edges and the text.
    static let margin: CGFloat = 8
    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.setAccessibilityIdentifier("ssh.terminal.container")
        attach(to: container)
        return container
    }
    func updateNSView(_ container: NSView, context: Context) {
        attach(to: container)
        session.apply(theme: theme, scale: scale)
        container.layer?.backgroundColor = theme.background.nsColor.cgColor
    }
    private func attach(to container: NSView) {
        container.layer?.backgroundColor = theme.background.nsColor.cgColor
        let view = session.view
        guard view.superview !== container else { return }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Self.margin),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Self.margin),
            view.topAnchor.constraint(equalTo: container.topAnchor, constant: Self.margin),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Self.margin),
        ])
        session.apply(theme: theme, scale: scale)
    }
}
