import AppKit
import SwiftUI

struct AppearanceSettings: View {
    @Bindable var themes = ThemeStore.shared
    var body: some View {
        Form {
            Section(L("settings.theme")) {
                Picker(L("settings.family"), selection: $themes.family) {
                    Text(L("themeButake")).tag(ThemeStore.Family.butake)
                    Text(L("themeDracula")).tag(ThemeStore.Family.dracula)
                    Text(L("themeCustom")).tag(ThemeStore.Family.custom)
                }.accessibilityIdentifier("settings.themeFamily")
                Picker(L("settings.mode"), selection: $themes.mode) {
                    Label(L("settings.system"), systemImage: Symbols.themeSystem).tag(ThemeStore.Mode.system)
                    Label(L("settings.light"), systemImage: Symbols.lightMode).tag(ThemeStore.Mode.light)
                    Label(L("settings.dark"), systemImage: Symbols.darkMode).tag(ThemeStore.Mode.dark)
                }.pickerStyle(.segmented).accessibilityIdentifier("settings.themeMode")
                ThemePreview(theme: themes.theme)
                if themes.family == .custom {
                    Picker(L("settings.base"), selection: $themes.customBase) {
                        Text(L("themeButake")).tag(ThemeStore.Family.butake); Text(L("themeDracula")).tag(ThemeStore.Family.dracula)
                    }.accessibilityIdentifier("settings.themeBase")
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                        ForEach(ThemeStore.Slot.allCases) { slot in
                            ColorPicker(L("themeSlot.\(slot.rawValue)"), selection: Binding(get: { Brand.color(for: slot).color }, set: { themes.set(slot, HexColor($0)) }), supportsOpacity: false)
                                .accessibilityIdentifier("settings.themeColor.\(slot.rawValue)")
                        }
                    }
                    Button { themes.resetCustom() } label: { Label(L("settings.resetCustom"), systemImage: Symbols.reload) }.accessibilityIdentifier("settings.themeReset")
                } else {
                    Button { themes.customBase = themes.family; themes.family = .custom } label: { Label(L("settings.customize"), systemImage: Symbols.appearance) }
                        .accessibilityIdentifier("settings.themeCustomize")
                }
            }
        }
        .formStyle(.grouped).themedScroll()
    }
}

/// What the theme touches in Stack: accent, state colors and surfaces.
private struct ThemePreview: View {
    let theme: Theme
    var body: some View {
        HStack(spacing: 8) {
            Text(theme.name).font(.uiCallout.weight(.semibold))
            Spacer()
            chip(L("state.running"), theme.addition)
            chip(L("state.starting"), theme.warning)
            chip(L("state.crashed"), theme.deletion)
            Text(L("activation.enable")).font(.uiSubheadline.weight(.semibold)).foregroundStyle(.white)
                .padding(.horizontal, 10).padding(.vertical, 4).background(Brand.accent, in: Capsule())
        }
        .padding(12)
        .background(Brand.surface(for: theme), in: RoundedRectangle(cornerRadius: 10))
        .padding(6)
        .background(Brand.background(for: theme), in: RoundedRectangle(cornerRadius: 14))
        .environment(\.colorScheme, theme.isDark ? .dark : .light)
    }
    private func chip(_ text: String, _ color: HexColor) -> some View {
        Text(text).font(.uiCaption2.weight(.semibold)).foregroundStyle(color.color)
            .padding(.horizontal, 6).padding(.vertical, 2).background(color.color.opacity(0.14), in: Capsule())
    }
}
