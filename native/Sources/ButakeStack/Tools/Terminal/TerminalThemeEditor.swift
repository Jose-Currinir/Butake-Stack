import SwiftUI

/// Saved terminal themes: copy one and change its colors and size.
struct TerminalThemeEditor: View {
    @Bindable var workspace: SSHWorkspace
    @State private var draft: TerminalTheme
    init(workspace: SSHWorkspace) {
        self.workspace = workspace
        var base = workspace.theme
        if base.builtin {
            base.id = "custom-\(UUID().uuidString.prefix(8).lowercased())"
            base.name = String(format: L("ssh.terminal.themeCopy"), base.name)
            base.builtin = false
        }
        _draft = State(initialValue: base)
    }
    var body: some View {
        SheetFrame(title: L("ssh.terminal.editThemes"), symbol: Symbols.appearance, width: 640, actionTitle: L("ssh.terminal.saveTheme"),
                   actionID: "ssh.theme.save", canAct: !draft.name.trimmingCharacters(in: .whitespaces).isEmpty, cancelID: "ssh.theme.cancel") {
            workspace.customThemes.removeAll { $0.id == draft.id }
            workspace.customThemes.append(draft)
            workspace.themeID = draft.id
            return true
        } content: {
            HStack(alignment: .top, spacing: 0) {
                Form {
                    TextField(L("ssh.terminal.themeName"), text: $draft.name).formField(L("common.name"))
                        .accessibilityIdentifier("ssh.theme.name")
                    colorRow(L("ssh.terminal.color.background"), \.background)
                    colorRow(L("ssh.terminal.color.foreground"), \.foreground)
                    colorRow(L("ssh.terminal.color.cursor"), \.cursor)
                    colorRow(L("ssh.terminal.color.selection"), \.selection)
                    Stepper(value: $draft.fontSize, in: 9...24, step: 0.5) {
                        LabeledContent(L("ssh.terminal.fontSize")) { Text(String(format: "%.1f pt", draft.fontSize)).monospacedDigit() }
                    }
                    .help(L("ssh.terminal.fontSizeHelp"))
                    .accessibilityIdentifier("ssh.theme.fontSize")
                    if !workspace.customThemes.isEmpty {
                        Section(L("ssh.terminal.savedThemes")) {
                            ForEach(workspace.customThemes) { theme in
                                LabeledContent(theme.name) {
                                    HStack(spacing: 4) {
                                        Button { workspace.themeID = theme.id; draft = theme } label: { Label(L("ssh.terminal.useTheme"), systemImage: Symbols.selected) }
                                            .buttonStyle(.bordered).accessibilityIdentifier("ssh.theme.use.\(theme.id)")
                                        Button {
                                            workspace.customThemes.removeAll { $0.id == theme.id }
                                            if workspace.themeID == theme.id { workspace.themeID = "auto" }
                                        } label: { Label(L("ssh.terminal.deleteTheme"), systemImage: Symbols.delete).labelStyle(.iconOnly) }
                                            .buttonStyle(.borderless).help(L("ssh.terminal.deleteTheme")).accessibilityIdentifier("ssh.theme.delete.\(theme.id)")
                                    }
                                }
                            }
                        }
                    }
                }
                .formStyle(.grouped).themedScroll()
                .frame(minWidth: 320, minHeight: 300)
                preview.padding(.top, 20).padding(.trailing, 20)
            }
        }
    }

    /// A few lines in the theme's colors and size.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "usuario@servidor:~$ ls").foregroundStyle(Color(nsColor: draft.foreground.nsColor))
            HStack(spacing: 8) {
                ForEach(0..<6, id: \.self) { index in
                    Text(verbatim: ["app", "logs", "a.txt", "deploy", "env", "tmp"][index]).foregroundStyle(Color(nsColor: draft.ansi[index + 1].nsColor))
                }
            }
            Text(verbatim: "█").foregroundStyle(Color(nsColor: draft.cursor.nsColor))
        }
        .font(.drawing(draft.fontSize, design: .monospaced))
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 140, alignment: .topLeading)
        .background(Color(nsColor: draft.background.nsColor), in: RoundedRectangle(cornerRadius: 10))  // radius 10: outside the Radius scale, kept as it was
        .accessibilityHidden(true)
    }

    func colorRow(_ title: String, _ path: WritableKeyPath<TerminalTheme, UInt32>) -> some View {
        ColorPicker(title, selection: Binding(
            get: { Color(nsColor: draft[keyPath: path].nsColor) },
            set: { draft[keyPath: path] = HexColor($0).value }
        ), supportsOpacity: false)
    }
}
