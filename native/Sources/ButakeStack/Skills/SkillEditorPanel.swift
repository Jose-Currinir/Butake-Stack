import SwiftUI

/// What the editor does when `SKILL.md` changed on disk: compares the file with what the editor last
/// saved and with the text on screen.
enum SkillEditorSync {
    enum Action: Equatable { case none, markSaved, reload, conflict }

    static func resolve(disk: String, saved: String, text: String) -> Action {
        if disk == saved { return .none }
        // Stack's own save may land before the editor notes it.
        if disk == text { return .markSaved }
        return text == saved ? .reload : .conflict
    }
}

/// The editor of a skill's `SKILL.md`: the whole file, frontmatter included. The engine is the only
/// writer; «Guardar» sends the text and the skill is read again from what it parsed.
struct SkillEditorPanel: View {
    let tool: SkillsTool
    let skill: Skill
    @State private var text = ""
    @State private var saved = ""
    @State private var loaded = false
    /// What `SKILL.md` says now, when it changed outside Stack while there is unsaved text.
    @State private var outside: String?

    /// The most the engine accepts for one `SKILL.md`.
    static let limit = 256 * 1024

    private var dirty: Bool { loaded && text != saved }
    private var tooLarge: Bool { text.utf8.count > Self.limit }

    var body: some View {
        Section {
            if outside != nil {
                Notice(.warning, L("skills.editor.outside.title"), detail: L("skills.editor.outside.detail")) {
                    Button(L("skills.editor.outside.reload")) { reload() }
                        .buttonStyle(.bordered).accessibilityIdentifier("skills.editor.outside.reload")
                    Button(L("skills.editor.outside.keep")) { keep() }
                        .buttonStyle(.bordered).accessibilityIdentifier("skills.editor.outside.keep")
                }
                .accessibilityIdentifier("skills.editor.outside")
            }
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
            outside = nil
            let read = await tool.read(skill.id)
            text = read ?? ""
            saved = text
            loaded = read != nil
            #if DEBUG
            if let typed = QAHooks.skillsTyped { text += typed }
            #endif
        }
        .onChange(of: skill.modified) { Task { await syncWithDisk() } }
        .onChange(of: dirty) { tool.unsavedSkill = dirty ? skill.id : nil }
        .onDisappear { tool.unsavedSkill = nil }
    }

    /// `SKILL.md` changed: take it when nothing was typed, ask when something was.
    private func syncWithDisk() async {
        guard loaded, let disk = await tool.read(skill.id) else { return }
        switch SkillEditorSync.resolve(disk: disk, saved: saved, text: text) {
        case .none: outside = nil
        case .markSaved: saved = text; outside = nil
        case .reload: text = disk; saved = disk; outside = nil
        case .conflict: outside = disk
        }
    }

    private func reload() {
        guard let outside else { return }
        text = outside
        saved = outside
        self.outside = nil
    }

    /// Keeps what was typed: from now on it is compared with the outside version, so saving replaces it knowingly.
    private func keep() {
        if let outside { saved = outside }
        outside = nil
    }
}
