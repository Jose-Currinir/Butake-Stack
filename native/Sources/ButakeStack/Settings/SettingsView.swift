import AppKit
import SwiftUI

/// Ajustes (⌘,), in tabs like System Settings and every Mac app. Each tab is a grouped form with
/// its own minimum and ideal size: the window takes the size of the tab it shows.
struct SettingsView: View {
    @Bindable var store: StackStore
    @Bindable var router = SettingsRouter.shared
    var body: some View {
        TabView(selection: $router.tab) {
            Tab(SettingsTab.general.title, systemImage: SettingsTab.general.symbol, value: .general) {
                GeneralSettings(store: store).settingsSize(height: 430)
            }
            Tab(SettingsTab.appearance.title, systemImage: SettingsTab.appearance.symbol, value: .appearance) {
                AppearanceSettings().settingsSize(height: 360)
            }
            Tab(SettingsTab.network.title, systemImage: SettingsTab.network.symbol, value: .network) {
                NetworkSettings(store: store).settingsSize(height: 640)
            }
            Tab(SettingsTab.tools.title, systemImage: SettingsTab.tools.symbol, value: .tools) {
                ToolsSettings(store: store).settingsSize(height: 400)
            }
            // The accounts of GitHub and Bitbucket belong to the Git tool: off, the tab is not there.
            if store.pluginEnabled("git") {
                Tab(SettingsTab.accounts.title, systemImage: SettingsTab.accounts.symbol, value: .accounts) {
                    GitAccountsSettings().settingsSize(height: 600)
                }
            }
            Tab(SettingsTab.keys.title, systemImage: SettingsTab.keys.symbol, value: .keys) {
                SSHKeysSection().settingsSize(height: 460)
            }
            Tab(SettingsTab.advanced.title, systemImage: SettingsTab.advanced.symbol, value: .advanced) {
                AdvancedSettings(store: store).settingsSize(height: 620)
            }
        }
        .accessibilityIdentifier("settings.tabs")
        // A tab whose tool was turned off (Cuentas) leaves the window on General.
        .onChange(of: store.pluginEnabled("git"), initial: true) { if router.tab == .accounts && !store.pluginEnabled("git") { router.tab = .general } }
    }
}

private extension View {
    /// A tab's size: a minimum that keeps its rows readable and an ideal the window opens at.
    func settingsSize(height: CGFloat) -> some View {
        frame(minWidth: 520, idealWidth: 600, minHeight: 280, idealHeight: height).fixedSize()
    }
}
