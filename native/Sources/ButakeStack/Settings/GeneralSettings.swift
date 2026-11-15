import AppKit
import SwiftUI

/// Ajustes › General: starting with the session, text size, updates and version.
struct GeneralSettings: View {
    @Bindable var store: StackStore
    @Bindable var text = TextScale.shared
    var body: some View {
        Form {
            LoginSection(store: store)
            Section(L("settings.text")) {
                LabeledContent(L("settings.textSize")) {
                    Stepper {
                        Text(String(format: L("settings.textPercent"), Int((text.factor * 100).rounded()))).monospacedDigit()
                    } onIncrement: {
                        if text.canIncrease { text.increase() }
                    } onDecrement: {
                        if text.canDecrease { text.decrease() }
                    }
                    .accessibilityIdentifier("settings.textSize")
                }
            }
            UpdateSettingsSection()
        }
        .formStyle(.grouped).themedScroll()
    }
}

/// Iniciar con la sesión: the session agent gets ports 53, 80 and 443 from macOS. The switch does
/// it; turning it off asks first (the projects stop being served).
private struct LoginSection: View {
    @Bindable var store: StackStore
    @Environment(\.openWindow) private var openWindow
    @State private var confirmOff = false
    var active: Bool { store.agent?.loaded == true }
    var phpReady: Bool { store.phpRuntimes.contains(where: \.verified) }
    var busyPorts: [String] {
        guard let ports = store.ports else { return [] }
        let ours: Set<String> = ["launchd", "butake-stack", "caddy"]
        let pairs: [(String, String?)] = [("53", ports.dns), ("80", ports.http), ("443", ports.https)]
        return pairs.compactMap { port, owner in
            guard let owner, !ours.contains(owner) else { return nil }
            return "\(port): \(owner)"
        }
    }
    /// PHP matters only when there are PHP projects (or the user works with Laravel/PHP).
    var needsPhp: Bool { store.projects.contains { $0.php != nil } || WorkProfile.chosen.contains("laravel") }
    var ready: Bool { (!needsPhp || phpReady) && store.caddyReady && busyPorts.isEmpty && !store.projects.isEmpty }

    var body: some View {
        Section {
            Toggle(isOn: Binding(get: { active }, set: { on in
                if on { Task { await store.installAgent() } } else { confirmOff = true }
            })) {
                Text(L("activation.title"))
                Text(active ? L("settings.loginOn") : L("settings.loginOff")).foregroundStyle(.secondary)
            }
            .disabled((!active && !ready) || store.busy != nil)
            .help(L("activation.help"))
            .accessibilityIdentifier("settings.login")
            if !active && !ready {
                if needsPhp {
                    requirement(phpReady, L("activation.php"), id: "php") { show(.language("php")) }
                }
                requirement(store.caddyReady, L("activation.caddy"), id: "caddy") { SettingsRouter.shared.tab = .network }
                requirement(!store.projects.isEmpty, L("activation.sites"), id: "sites") { openWindow(id: "main"); store.chooseFolder() }
                requirement(busyPorts.isEmpty, busyPorts.isEmpty ? L("activation.ports") : String(format: L("activation.portsBusy"), busyPorts.joined(separator: ", ")), id: "ports", go: nil)
            }
        } header: {
            Text(L("settings.startup"))
        }
        .task { await store.refreshPorts() }
        .confirmationDialog(L("activation.confirmOff"), isPresented: $confirmOff) {
            Button(L("activation.disable"), role: .destructive) { Task { await store.uninstallAgent() } }
                .accessibilityIdentifier("settings.login.confirmOff")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("activation.confirmOffDetail")) }
    }

    private func show(_ route: Route) {
        store.route = route
        openWindow(id: "main")
    }

    /// What the switch needs before it can be turned on, with a button to the place that solves it.
    private func requirement(_ ok: Bool, _ text: String, id: String, go: (() -> Void)?) -> some View {
        LabeledContent {
            if !ok, let go {
                Button(action: go) { Label(L("activation.go"), systemImage: Symbols.forward) }
                    .accessibilityIdentifier("settings.login.go.\(id)")
            }
        } label: {
            Label {
                Text(text)
            } icon: {
                Image(systemName: ok ? Symbols.success : Symbols.warning).foregroundStyle(ok ? Brand.success : Brand.warning)
            }
        }
    }
}
