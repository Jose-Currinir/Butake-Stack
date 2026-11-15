import AppKit
import SwiftUI

/// The Git tool's toolbar (DISENO.md): the tabs, the current branch (switch, create, search) and
/// the primary sync button, whose title follows the repository's state.
struct GitToolbar: ToolbarContent {
    @Bindable var tool: GitTool
    @Bindable var repository: GitRepository
    /// Width of the detail column: the tabs take what the branch and the sync button leave.
    let detailWidth: CGFloat

    /// Room the branch menu, the sync button, the window's «+» and the toolbar's gaps take on the
    /// right (with a margin: the estimate errs on the safe side). Worked out from their titles, never
    /// measured on screen: a toolbar item that changes
    /// with what another one measures makes the toolbar lay itself out without end.
    private var trailing: CGFloat {
        GitToolbarWidth.button(repository.branchTitle) + 24 + GitToolbarWidth.button(repository.syncState.title) + 68
    }

    var body: some ToolbarContent {
        // Everything over the detail: a control in `.navigation` or `.principal` would cross the
        // content column's divider. `.primaryAction` keeps them in the detail's part of the toolbar at
        // every width (a `.secondaryAction` follows the window title, over the content column, when
        // space is short); the titled tabs take the room the rest leaves, so they start at the
        // detail's edge.
        ToolbarItem(placement: .primaryAction) {
            GitTabPicker(tool: tool, repository: repository, width: max(60, detailWidth - trailing - 28))
        }
        ToolbarItemGroup(placement: .primaryAction) {
            GitBranchMenu(repository: repository)
            GitSyncButton(repository: repository)
        }
    }
}

/// Widths of the toolbar's controls from their titles, with the system font the toolbar uses.
@MainActor enum GitToolbarWidth {
    /// A button or tab with a symbol and a title.
    /// At the app's text size: the toolbar's titles grow with it.
    static func button(_ title: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: TextScale.points(NSFont.systemFontSize))
        return ceil((title as NSString).size(withAttributes: [.font: font]).width) + TextScale.points(32)
    }
    /// The five titled tabs, side by side, at the small control size they use.
    static func tabs(_ titles: [String]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: TextScale.points(NSFont.smallSystemFontSize))
        let text = titles.map { ceil(($0 as NSString).size(withAttributes: [.font: font]).width) + TextScale.points(30) }
        return text.reduce(0, +) + CGFloat(max(0, titles.count - 1)) * 2
    }
}

/// The tabs, with symbol and title («Problemas» with its count); only when the window is too narrow
/// for the titles they become one pop-up with the tab's symbol, with the title in its tooltip.
struct GitTabPicker: View {
    @Bindable var tool: GitTool
    let repository: GitRepository
    let width: CGFloat

    var body: some View {
        // Each tab as wide as its title (a segmented control makes them all as wide as the longest).
        // When the window can't hold the titles, one pop-up with the symbol of the tab on screen (its
        // title in the tooltip) and every tab with its title inside: five bare symbols would still
        // push the toolbar over the content column's divider.
        Group {
            if width >= GitToolbarWidth.tabs(GitTab.allCases.map { $0.title(repository) }) {
                titled.frame(width: width, alignment: .leading)
            } else {
                compact
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(L("git.tab.label"))
        .accessibilityIdentifier("git.toolbar.tabs")
    }

    private var titled: some View {
        HStack(spacing: 2) {
            ForEach(GitTab.allCases) { tab in
                Toggle(isOn: Binding(get: { tool.tab == tab }, set: { if $0 { tool.tab = tab } })) {
                    Label(tab.title(repository), systemImage: tab.symbol).labelStyle(.titleAndIcon)
                }
                .toggleStyle(.button)
                .help(tab.title(repository))
                .accessibilityIdentifier("git.tab.\(tab.rawValue)")
            }
        }
        // Small, so the titles fit beside the branch and the sync button in a usual window.
        .controlSize(.small)
        .fixedSize()
    }

    private var compact: some View {
        Menu {
            ForEach(GitTab.allCases) { tab in
                Toggle(isOn: Binding(get: { tool.tab == tab }, set: { if $0 { tool.tab = tab } })) {
                    Label(tab.title(repository), systemImage: tab.symbol)
                }
                .accessibilityIdentifier("git.tab.\(tab.rawValue)")
            }
        } label: {
            Label(tool.tab.title(repository), systemImage: tool.tab.symbol).labelStyle(.iconOnly)
        }
        // Its own width only: left to itself the pop-up asks for its title's room too.
        .frame(width: 52)
        .help(String(format: L("git.tab.compactHelp"), tool.tab.title(repository)))
    }
}

/// The current branch: switch to another (local or remote), create one, find one.
struct GitBranchMenu: View {
    @Bindable var repository: GitRepository
    @Bindable var tool = GitTool.shared
    @State private var finding = false

    var body: some View {
        Menu {
            Button { tool.creatingBranch = true } label: { Label(L("git.branch.newEllipsis"), systemImage: Symbols.gitNewBranch) }
                .accessibilityIdentifier("git.branchMenu.new")
            Button { finding = true } label: { Label(L("git.branch.findEllipsis"), systemImage: Symbols.search) }
                .accessibilityIdentifier("git.branchMenu.find")
            Divider()
            Section(L("git.branch.local")) {
                ForEach(repository.localBranches.prefix(15)) { branch in
                    Button { requestSwitch(branch.name) } label: {
                        Label(branch.name, systemImage: branch.current ? Symbols.selected : Symbols.git)
                    }
                    .disabled(branch.current)
                    .accessibilityIdentifier("git.branchMenu.switch.\(branch.name)")
                }
            }
        } label: {
            Label(repository.branchTitle, systemImage: Symbols.git)
                .labelStyle(.titleAndIcon)
        }
        .disabled(repository.busy)
        .help(L("git.branch.menuHelp"))
        .accessibilityIdentifier("git.toolbar.branch")
        .sheet(isPresented: $finding) { GitBranchFinderSheet(repository: repository) { requestSwitch($0) }.themedSheet() }
    }

    private func requestSwitch(_ name: String) { GitBranchActions.shared.requestSwitch(name, in: repository) }
}

/// The primary sync button: one action that follows the state, its count in the title. While a
/// transfer runs it shows progress and «Cancelar».
struct GitSyncButton: View {
    @Bindable var repository: GitRepository
    @State private var confirmingMain = false

    var body: some View {
        let state = repository.syncState
        if case .running(let title, let cancellable) = state {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(title).font(.uiCallout).foregroundStyle(.secondary).lineLimit(1)
                if cancellable {
                    Button { repository.cancel() } label: { Label(L("common.cancel"), systemImage: Symbols.close) }
                        .help(L("git.sync.cancelHelp")).accessibilityIdentifier("git.sync.cancel")
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier(state.identifier)
        } else {
            Button {
                if case .push = state, repository.snapshot.branch == repository.snapshot.primaryBranch { confirmingMain = true }
                else { Task { await repository.sync() } }
            } label: {
                Label(state.title, systemImage: state.symbol).labelStyle(.titleAndIcon)
            }
            .help(state.help)
            .accessibilityIdentifier(state.identifier)
            .confirmationDialog(String(format: L("git.sync.pushMainTitle"), repository.snapshot.primaryBranch), isPresented: $confirmingMain) {
                Button(L("git.sync.pushMainConfirm")) { Task { await repository.sync() } }
                    .accessibilityIdentifier("git.sync.pushMainConfirm")
                Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.sync.pushMainCancel")
            } message: {
                Text(L("git.sync.pushMainDetail"))
            }
        }
    }
}
