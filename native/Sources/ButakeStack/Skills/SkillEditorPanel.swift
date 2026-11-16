import SwiftUI

/// The editor of a skill's `SKILL.md`: the whole file, frontmatter included. The engine is the only
/// writer; «Guardar» sends the text and the skill is read again from what it parsed.
struct SkillEditorPanel: View {
    let tool: SkillsTool
    let skill: Skill
    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false

    /// The most the engine accepts for one `SKILL.md`.
    static let limit = 256 * 1024

    private var dirty: Bool { loaded && text != saved }
    private var tooLarge: Bool { text.utf8.count > Self.limit }

    var body: some View {
        Section {
            TextEditor(text: $text)
                .font(.uiMonospaced)
                .frame(minHeight: 280)
                .disabled(!loaded)
                .overlay { if !loaded { ProgressView().controlSize(.small) } }
                .accessibilityLabel(L("skills.editor"))
                .accessibilityIdentifier("skills.editor.text")
            HStack {
                if tooLarge {
                    Label(L("error.skills_too_large"), systemImage: Symbols.warning).font(.uiCaption).foregroundStyle(Brand.warning)
                        .accessibilityIdentifier("skills.editor.tooLarge")
                } else if dirty {
                    Text(L("skills.editor.unsaved")).font(.uiCaption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("skills.editor.unsaved")
                }
                Spacer()
                Button(L("skills.editor.discard")) { text = saved }
                    .disabled(!dirty).accessibilityIdentifier("skills.editor.discard")
                Button { Task { if await tool.save(skill.id, text: text) { saved = text } } } label: {
                    Label(L("common.save"), systemImage: Symbols.save)
                }
                .buttonStyle(.borderedProminent).keyboardShortcut("s", modifiers: .command)
                .disabled(!dirty || tooLarge).help(L("skills.editor.saveHelp")).accessibilityIdentifier("skills.editor.save")
            }
        } header: {
            Text(L("skills.section.editor"))
        } footer: {
            SettingsFooter(L("skills.editor.footer"))
        }
        .task(id: skill.id) {
            let read = await tool.read(skill.id)
            text = read ?? ""
            saved = text
            loaded = read != nil
        }
    }
}
