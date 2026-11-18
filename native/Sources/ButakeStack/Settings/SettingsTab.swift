import SwiftUI

/// The tabs of Ajustes (⌘,), in the order of the window.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general, appearance, network, tools, accounts, keys, advanced
    var id: String { rawValue }
    var title: String { L("settings.tab.\(rawValue)") }
    var symbol: String {
        switch self {
        case .general: Symbols.settings
        case .appearance: Symbols.appearance
        case .network: Symbols.network
        case .tools: Symbols.tools
        case .accounts: Symbols.gitAccounts
        case .keys: Symbols.key
        case .advanced: Symbols.advanced
        }
    }
}

/// Opens Ajustes on a tab from anywhere (a link, a menu, the palette, a page): the windows that
/// can open the Settings scene watch `requests` (see `opensSettings()`).
@MainActor @Observable final class SettingsRouter {
    static let shared = SettingsRouter()
    /// The tab on screen, kept between launches like the window's page.
    var tab: SettingsTab = SettingsTab(rawValue: UserDefaults.standard.string(forKey: "settings.tab") ?? "") ?? .general {
        didSet {
            UserDefaults.standard.set(tab.rawValue, forKey: "settings.tab")
            highlightedTool = nil
        }
    }
    /// The tool whose row Herramientas highlights: a link led to a tool that is off.
    var highlightedTool: String?
    private(set) var requests = 0

    func open(_ tab: SettingsTab, tool: String? = nil) {
        self.tab = tab
        highlightedTool = tool
        requests += 1
    }
}

extension View {
    /// Opens the Settings scene when `SettingsRouter` asks for it.
    func opensSettings() -> some View { modifier(SettingsOpener()) }
}

private struct SettingsOpener: ViewModifier {
    @Environment(\.openSettings) private var openSettings
    func body(content: Content) -> some View {
        content.onChange(of: SettingsRouter.shared.requests) { openSettings() }
    }
}

/// The note under a section of Ajustes, aligned with the rows like System Settings.
struct SettingsFooter: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.uiCaption).foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
