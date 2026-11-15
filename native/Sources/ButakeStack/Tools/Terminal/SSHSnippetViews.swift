import SwiftUI

// MARK: - In a terminal

/// Saved commands for the active terminal (Terminal › Insertar snippet…): insert (nothing runs) or
/// run (adds Return).
struct SnippetPicker: View {
    let session: TerminalSession?
    @Environment(\.dismiss) private var dismiss
    @Bindable var snippets = SSHSnippets.shared
    @Bindable var workspace = SSHWorkspace.shared
    @State private var search = ""
    @State private var refused = false
    var body: some View {
        let list = snippets.available(for: session?.kind).filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.command.localizedCaseInsensitiveContains(search) }
        SheetFrame(title: L("ssh.snippets.title"), symbol: Symbols.snippets, detail: L("ssh.snippets.formHelp"), width: 520,
                   actionTitle: L("common.done"), actionID: "ssh.snippets.pickerDone", action: { true }) {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L("ssh.snippets.search"), text: $search).textFieldStyle(.roundedBorder).accessibilityIdentifier("ssh.snippets.search")
                Button { dismiss(); Task { try? await Task.sleep(for: .milliseconds(350)); workspace.sheet = .snippets } } label: { Label(L("ssh.snippets.manage"), systemImage: Symbols.edit) }
                    .buttonStyle(.bordered).accessibilityIdentifier("ssh.snippets.manage")
            }
            if list.isEmpty {
                ContentUnavailableView(snippets.list.isEmpty ? L("ssh.snippets.empty") : L("ssh.snippets.noMatch"), systemImage: Symbols.snippets)
                    .frame(minHeight: 120)
            } else {
                List(list) { snippet in
                    LabeledContent {
                        HStack(spacing: 6) {
                            Button { use(snippet, run: false) } label: { Label(L("ssh.snippets.insert"), systemImage: Symbols.snippets) }
                                .buttonStyle(.bordered).accessibilityIdentifier("ssh.snippets.insert.\(snippet.id)")
                            Button { use(snippet, run: true) } label: { Label(L("ssh.snippets.run"), systemImage: Symbols.start) }
                                .buttonStyle(.bordered).accessibilityIdentifier("ssh.snippets.run.\(snippet.id)")
                        }
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 4) {
                                Text(snippet.name).font(.uiCallout.weight(.semibold))
                                if snippet.host != nil {
                                    Image(systemName: Symbols.server).font(.uiCaption).foregroundStyle(.secondary).help(L("ssh.snippets.hostOnly"))
                                        .accessibilityLabel(L("ssh.snippets.hostOnly"))
                                }
                            }
                            Text(snippet.command).font(.uiSubheadline.monospaced()).foregroundStyle(.secondary).lineLimit(2).truncationMode(.tail)
                        }
                    }
                }
                .frame(minHeight: 160, maxHeight: 320)
            }
            if refused {
                Text(L("ssh.snippets.multilineRefused")).font(.uiCaption).foregroundStyle(Brand.warning)
            }
        }
        }
        .task { if !snippets.loaded { await snippets.load() } }
    }
    func use(_ snippet: SSHSnippet, run: Bool) {
        guard let session else { return }
        if session.insert(snippet.command, run: run) { dismiss() } else { refused = true }
    }
}

// MARK: - Managing them

/// Saved commands: global (every terminal) or for one host.
struct SnippetsSheet: View {
    var hostID: String?
    @Bindable var snippets = SSHSnippets.shared
    @Bindable var terminal = SSHTerminal.shared
    @State private var editing: SSHSnippet?
    @State private var deleting: SSHSnippet?
    var body: some View {
        SheetFrame(title: L("ssh.snippets.title"), symbol: Symbols.snippets, detail: L("ssh.snippets.subtitle"), note: L("ssh.snippets.privacy"),
                   width: 600, height: 460, actionTitle: L("common.done"), actionID: "ssh.snippets.done", action: { true }) {
            Form {
                Section {
                    if snippets.list.isEmpty {
                        ContentUnavailableView(L("ssh.snippets.empty"), systemImage: Symbols.snippets)
                    }
                    ForEach(snippets.list) { snippet in
                        LabeledContent {
                            HStack(spacing: 4) {
                                Button { editing = snippet } label: { Label(L("ssh.snippets.edit"), systemImage: Symbols.edit).labelStyle(.iconOnly) }
                                    .buttonStyle(.borderless).help(L("ssh.snippets.edit")).accessibilityIdentifier("ssh.snippets.edit.\(snippet.id)")
                                Button { deleting = snippet } label: { Label(L("ssh.snippets.delete"), systemImage: Symbols.delete).labelStyle(.iconOnly) }
                                    .buttonStyle(.borderless).help(L("ssh.snippets.delete")).accessibilityIdentifier("ssh.snippets.delete.\(snippet.id)")
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                HStack(spacing: 6) {
                                    Text(snippet.name)
                                    Chip(text: snippet.host.flatMap { terminal.host($0)?.name } ?? L("ssh.snippets.global"))
                                }
                                if !snippet.description.isEmpty { Text(snippet.description).font(.uiCaption).foregroundStyle(.secondary) }
                                Text(snippet.command).font(.uiSubheadline.monospaced()).foregroundStyle(.secondary).lineLimit(3).textSelection(.enabled)
                            }
                        }
                    }
                } footer: {
                    HStack {
                        Spacer()
                        Button { editing = SSHSnippet(host: hostID) } label: { Label(L("ssh.snippets.newEllipsis"), systemImage: Symbols.add) }
                            .buttonStyle(.bordered).accessibilityIdentifier("ssh.snippets.new")
                    }
                }
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 280)
        }
        .task { await snippets.load() }
        .sheet(item: $editing) { snippet in SnippetForm(original: snippet).themedSheet() }
        .confirmationDialog(String(format: L("ssh.snippets.deleteConfirm"), deleting?.name ?? ""), isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button(L("ssh.snippets.delete"), role: .destructive) { if let snippet = deleting { Task { await snippets.delete(snippet) } }; deleting = nil }
                .accessibilityIdentifier("ssh.snippets.confirmDelete")
            Button(L("common.cancel"), role: .cancel) {}
        }
    }
}

private struct SnippetForm: View {
    let original: SSHSnippet
    @State private var snippet: SSHSnippet
    @Bindable var terminal = SSHTerminal.shared
    init(original: SSHSnippet) {
        self.original = original
        _snippet = State(initialValue: original)
    }
    var body: some View {
        SheetFrame(title: original.id.isEmpty ? L("ssh.snippets.new") : L("ssh.snippets.edit"), symbol: Symbols.snippets,
                   note: L("ssh.snippets.formHelp"), width: 540, actionTitle: L("common.save"), actionID: "ssh.snippets.form.save",
                   canAct: !snippet.name.trimmingCharacters(in: .whitespaces).isEmpty && !snippet.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                   cancelID: "ssh.snippets.form.cancel") {
            await SSHSnippets.shared.save(snippet)
        } content: {
            Form {
                TextField(L("common.name"), text: $snippet.name).formField(L("common.name")).accessibilityIdentifier("ssh.snippets.form.name")
                TextField(L("ssh.snippets.description"), text: $snippet.description).formField(L("ssh.description"))
                    .accessibilityIdentifier("ssh.snippets.form.description")
                LabeledContent(L("ssh.snippets.command")) {
                    TextEditor(text: $snippet.command)
                        .font(.uiCallout.monospaced())
                        .frame(minHeight: 90)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                        .accessibilityIdentifier("ssh.snippets.form.command")
                }
                Picker(L("ssh.snippets.scope"), selection: $snippet.host) {
                    Text(L("ssh.snippets.global")).tag(String?.none)
                    ForEach(terminal.hosts) { host in Text(host.name).tag(String?.some(host.id)) }
                }
                .accessibilityIdentifier("ssh.snippets.form.scope")
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: 280)
        }
    }
}
