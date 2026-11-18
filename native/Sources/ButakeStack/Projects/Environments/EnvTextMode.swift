import SwiftUI

/// An environment as the text of a `.env`, for Entornos' text mode. Secret values never reach the
/// text: a secret that has a value is the mask, and a line left with the mask keeps its value (R3).
/// Only `NAME=value` lines survive a save: the store keeps names, plain values and which are secret.
enum EnvText {
    typealias Row = EnvironmentsView.Row
    static let mask = "••••••••"

    /// `stored`: the secrets that have a value in the Keychain.
    static func render(_ rows: [Row], stored: Set<String>) -> String {
        rows.filter { !$0.key.isEmpty }.map { row in
            guard row.secret else { return "\(row.key)=\(quoted(row.value))" }
            return "\(row.key)=\(row.newSecret != nil || hasValue(row, stored) ? mask : "")"
        }.joined(separator: "\n") + "\n"
    }

    /// The rows the text describes. A name already in `rows` keeps its row (and whether it is
    /// secret); a new name is a plain row marked `fromText`, classified before it is saved (R2).
    /// Merging the same text again changes nothing.
    static func merge(_ text: String, into rows: [Row], stored: Set<String>) -> [Row] {
        var known: [String: Row] = [:]
        for row in rows where known[row.key] == nil { known[row.key] = row }
        return DotEnv.parse(text).map { key, value in
            guard var row = known[key] else { return Row(key: key, value: value == mask ? "" : value, secret: false, fromText: true) }
            if !row.secret {
                row.value = value
            } else if value != mask, !(value.isEmpty && row.newSecret == nil && !hasValue(row, stored)) {
                row.newSecret = value
            }
            return row
        }
    }

    private static func hasValue(_ row: Row, _ stored: Set<String>) -> Bool { row.original != nil && stored.contains(row.key) }

    /// Quoted only when `DotEnv.parse` would otherwise read something else.
    static func quoted(_ value: String) -> String {
        let plain = value == value.trimmingCharacters(in: .whitespaces) && !value.contains(" #") && !value.hasPrefix("\"") && !value.hasPrefix("'")
        if plain { return value }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// Edición › Buscar (⌘F) inside a page that shows a code editor: opens its find bar.
struct TextFinderRequest {
    let show: @MainActor () -> Void
}

extension FocusedValues {
    @Entry var textFinder: TextFinderRequest?
}

extension EnvironmentsView {
    /// Lista (one row per variable) or Texto (the whole environment as a `.env`).
    @ViewBuilder func modePicker(labeled: Bool) -> some View {
        let picker = Picker(L("env.view"), selection: $textMode) {
            Text(L("env.view.list")).tag(false)
            Text(L("env.view.text")).tag(true)
        }
        .pickerStyle(.segmented).labelsHidden().fixedSize()
        .help(L("env.view.help")).accessibilityIdentifier("env.view")
        if labeled { LabeledContent(L("env.view")) { picker } } else { picker }
    }

    /// Text mode: what the list's first section says, in two lines, and the editor in the rest.
    var textContent: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                notices
                missingNotice
                HStack(spacing: 10) {
                    environmentPicker.labelsHidden().fixedSize()
                    if let active = state?.site.activeEnvironment { Chip(env: active).help(String(format: L("env.activeHelp"), active.title)) }
                    Spacer()
                    modePicker(labeled: false)
                }
                actions
            }
            .padding(.horizontal, 20).padding(.vertical, 12)
            Divider()
            CodeEditor(text: Binding(get: { text }, set: { typed($0) }), path: ".env",
                       identifier: "env.text", label: L("env.text.label"), findRequests: findRequests)
            Divider()
            Text(String(format: L("env.text.note"), EnvText.mask))
                .font(.uiCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20).padding(.vertical, 8)
        }
        .focusedSceneValue(\.textFinder, TextFinderRequest { findRequests += 1 })
    }

    private func typed(_ value: String) {
        text = value
        let rows = EnvText.merge(value, into: draft, stored: storedSecrets)
        if rows != draft { draft = rows }
        if !dirty { dirty = true }
    }

    func renderText() { text = EnvText.render(draft, stored: storedSecrets) }

    /// The draft changed outside the editor (another environment, a new database, missing
    /// variables): the text follows. What was typed in the editor already matches and stays.
    func followDraft() {
        guard textMode, EnvText.merge(text, into: draft, stored: storedSecrets) != draft else { return }
        renderText()
    }

    func modeChanged() {
        if textMode {
            draft.removeAll { $0.key.isEmpty }
            renderText()
        } else {
            Task { await classifyTyped() }
        }
    }

    /// Names typed in the text that suggest a credential become secrets, their value on its way to
    /// the Keychain instead of the store (R2), before saving and when going back to the list.
    func classifyTyped() async {
        let typed = draft.filter { $0.fromText && !$0.secret }
        guard !typed.isEmpty else { return }
        let secret = await store.classify(typed.map(\.key))
        for (row, isSecret) in zip(typed, secret) {
            guard let index = draft.firstIndex(where: { $0.id == row.id }) else { continue }
            draft[index].fromText = false
            guard isSecret else { continue }
            draft[index].secret = true
            draft[index].newSecret = draft[index].value.isEmpty ? nil : draft[index].value
            draft[index].value = ""
        }
        if textMode { renderText() }
    }
}
