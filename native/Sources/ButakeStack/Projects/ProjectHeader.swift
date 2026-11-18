import AppKit
import SwiftUI

/// The head of a project's page: its logo and name in large type, «Laravel · PHP 8.4 · https://tienda.test»
/// under it (the address opens the browser), and on the right its state in words with its dot, the
/// ways to open it with their words, a «⋯» menu and the switch, Iniciar or Detener, last. A project
/// without a server has no state, no «Abrir» and no switch.
struct ProjectHeader: View {
    @Bindable var store: StackStore
    let project: Project
    let openSettings: () -> Void
    /// `DetailHeader.logoSize` without naming the header's generic arguments.
    @MainActor static var logoSize: CGFloat { DetailHeader<EmptyView, EmptyView, EmptyView>.logoSize }

    var body: some View {
        DetailHeader(title: project.title, logo: { logo }, subtitle: { subtitle }, actions: { actions })
    }

    private var logo: some View {
        TechLogo(tech: project.tech, size: Self.logoSize).accessibilityHidden(true)
    }

    @ViewBuilder private var actions: some View {
        if project.isServed { state }
        if project.isServed {
            Button(L("common.open")) { if let url = project.url { NSWorkspace.shared.open(url) } }
                .disabled(project.url == nil)
                .help(L("menu.openInBrowser")).accessibilityIdentifier("project.openBrowser")
        }
        Button(L("project.code")) { Editor.open(project.path) }
            .help(L("project.openEditor")).accessibilityIdentifier("project.openEditor")
        terminal
        more
        if project.isServed { power }
    }

    /// Kind, PHP version and address, as the sidebar and the window's subtitle name them.
    private var subtitle: some View {
        let kind = ([project.tech.title] + [project.php.map { "PHP \($0)" }].compactMap { $0 }).joined(separator: " · ")
        return HStack(spacing: 0) {
            Text(kind)
            if let url = project.url {
                Text(verbatim: " · ")
                Link(url.absoluteString, destination: url).accessibilityIdentifier("project.address")
            }
        }
    }

    /// «En ejecución» with its dot; Detenido when the project is off.
    private var state: some View {
        let phase = store.sitePhase(project)
        let word = project.enabled ? L("state.\(phase.rawValue)") : L("site.off")
        return HStack(spacing: 6) {
            StatusDot(color: phase.color, symbol: phase.markSymbol, label: word)
            Text(word).foregroundStyle(phase == .crashed && project.enabled ? Brand.dangerText : .secondary).lineLimit(1)
        }
        .padding(.trailing, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("project.state")
    }

    @ViewBuilder private var terminal: some View {
        if store.pluginEnabled("ssh-terminal") {
            // A click opens «Consola» in the project's folder; the menu, an assistant or Terminal.
            Menu {
                ProjectConsoleItems(project: project)
                Divider()
                Button { Editor.terminal(project.path) } label: { Label(L("project.openTerminal"), systemImage: Symbols.openInApp) }
                    .accessibilityIdentifier("project.openTerminal")
            } label: {
                Text(L("ssh.terminal.menu"))
            } primaryAction: {
                LocalConsoles.open(.shell, project: project)
            }
            .help(L("ssh.local.openHere")).accessibilityIdentifier("project.openConsole")
        } else {
            Button(L("ssh.terminal.menu")) { Editor.terminal(project.path) }
                .help(L("project.openTerminal")).accessibilityIdentifier("project.openTerminal")
        }
    }

    private var more: some View {
        Menu {
            Button { openSettings() } label: { Label(L("project.settings"), systemImage: Symbols.settings) }
                .accessibilityIdentifier("project.settings")
            if let url = project.url {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.absoluteString, forType: .string)
                } label: { Label(L("engine.copyAddress"), systemImage: Symbols.copy) }
                    .accessibilityIdentifier("project.copyAddress")
            }
        } label: {
            Label(L("project.more"), systemImage: Symbols.more).labelStyle(.iconOnly)
        }
        .menuIndicator(.hidden).fixedSize()
        .help(L("project.more")).accessibilityIdentifier("project.more")
    }

    private var power: some View {
        Button(project.enabled ? L("menu.stop") : L("menu.start")) {
            Task { await store.setSite(project, enabled: !project.enabled) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(project.isMissing)
        .help(L("site.power")).accessibilityIdentifier("project.power")
    }
}
