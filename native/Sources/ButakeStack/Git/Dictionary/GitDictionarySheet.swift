import SwiftUI

/// «Diccionario de Git»: Git's commands with a line in Spanish, whether this Mac's Git has each one,
/// its official documentation and its local manual; and the words of Git explained. A search on top,
/// the list and the selected entry side by side; everything reachable with the keyboard.
struct GitDictionarySheet: View {
    enum Mode: String, CaseIterable, Identifiable {
        case commands, concepts
        var id: String { rawValue }
        var title: String { L("git.dictionary.mode.\(rawValue)") }
    }

    private let dictionary = GitDictionary.shared
    @State private var mode: Mode = .concepts
    @State private var search = ""
    @State private var category: String?
    @State private var selection: String? = "commit"
    @State private var capabilities: GitCommandCapabilities?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                IconTile(symbol: Symbols.gitDictionary, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("git.dictionary.title")).font(.uiTitle3.weight(.semibold))
                    Text(L("git.dictionary.detail")).font(.uiCaption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker(L("git.dictionary.mode"), selection: $mode) {
                    ForEach(Mode.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .accessibilityIdentifier("git.dictionary.mode")
            }
            .padding(16)
            HStack(spacing: 8) {
                FilterField(text: $search, identifier: "git.dictionary.search", prompt: L("git.dictionary.search"))
                if mode == .commands {
                    Picker(L("git.dictionary.category"), selection: $category) {
                        Text(L("git.dictionary.category.all")).tag(String?.none)
                        Divider()
                        ForEach(GitDictionary.categories, id: \.self) { Text(L("git.dictionary.category.\($0)")).tag(String?.some($0)) }
                    }
                    .pickerStyle(.menu).fixedSize()
                    .accessibilityIdentifier("git.dictionary.category")
                }
            }
            .padding(.horizontal, 16).padding(.bottom, 10)
            Divider()
            Group {
                switch mode {
                case .commands: commands
                case .concepts: concepts
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            HStack {
                Text(footer).font(.uiCaption).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Button(L("common.close")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityIdentifier("git.dictionary.close")
            }
            .padding(16)
        }
        .frame(minWidth: 760, idealWidth: 860, minHeight: 520, idealHeight: 640)
        .task {
            #if DEBUG
            if let wanted = GitQA.dictionaryMode.flatMap(Mode.init(rawValue:)) { mode = wanted }
            #endif
            capabilities = try? await StackStore.shared.call(["method": "gitCapabilities"])
        }
        .accessibilityIdentifier("git.dictionary.sheet")
    }

    private var footer: String {
        let shown = mode == .commands ? dictionary.commands(matching: search, category: category).count : dictionary.concepts(matching: search).count
        let total = mode == .commands ? dictionary.commands.count : dictionary.concepts.count
        let count = String(format: L("git.dictionary.count"), shown, total)
        return capabilities.map { "\(count) · \($0.version)" } ?? count
    }

    private var commands: some View {
        let list = dictionary.commands(matching: search, category: category)
        return HSplitView {
            List(list, selection: $selection) { command in
                VStack(alignment: .leading, spacing: 1) {
                    Text(verbatim: command.name).font(.uiBody.monospaced())
                    Text(command.description).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
                }
                .tag(command.name)
                .accessibilityIdentifier("git.dictionary.command.\(command.name)")
            }
            .listStyle(.inset)
            .themedScroll()
            .frame(minWidth: 220, idealWidth: 280, maxWidth: 360)
            .accessibilityIdentifier("git.dictionary.commands")
            .overlay {
                if list.isEmpty { ContentUnavailableView.search(text: search) }
            }
            Group {
                if let command = list.first(where: { $0.name == selection }) {
                    GitDictionaryCommandDetail(command: command, capability: capabilities?.commands.first { $0.name == command.name })
                        .id(command.name)
                } else {
                    ContentUnavailableView(L("git.dictionary.choose"), systemImage: Symbols.gitDictionary,
                                           description: Text(L("git.dictionary.chooseDetail")))
                }
            }
            .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var concepts: some View {
        let list = dictionary.concepts(matching: search)
        return List(list) { concept in
            VStack(alignment: .leading, spacing: 4) {
                Text(concept.term).font(.uiHeadline)
                Text(concept.definition).font(.uiBody).foregroundStyle(.secondary).textSelection(.enabled)
            }
            .padding(.vertical, 4)
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("git.dictionary.concept.\(concept.id)")
        }
        .listStyle(.inset)
        .themedScroll()
        .accessibilityIdentifier("git.dictionary.concepts")
        .overlay {
            if list.isEmpty { ContentUnavailableView.search(text: search) }
        }
    }
}

/// A command: what it does, its category, whether this Mac's Git has it, its official documentation
/// and its manual page as this Mac's Git has it.
private struct GitDictionaryCommandDetail: View {
    let command: GitDictionary.Command
    let capability: GitCommandCapabilities.Command?
    @State private var manual: String?
    @State private var loading = false

    private var availability: String {
        guard let capability else { return L("git.dictionary.checking") }
        return L(capability.library ? "git.dictionary.library" : capability.available ? "git.dictionary.available" : "git.dictionary.unavailable")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L("git.dictionary.command")) { Text(verbatim: "git \(command.name)").font(.uiBody.monospaced()).textSelection(.enabled) }
                Text(command.description).textSelection(.enabled)
                LabeledContent(L("git.dictionary.category"), value: L("git.dictionary.category.\(command.category)"))
                LabeledContent(L("git.dictionary.onThisMac"), value: availability)
                if command.experimental {
                    LabeledContent(L("git.dictionary.experimental"), value: L("git.dictionary.experimentalValue"))
                }
            } footer: {
                SettingsFooter(L("git.dictionary.note"))
            }
            Section {
                HStack(spacing: 8) {
                    if let url = command.documentationURL {
                        Button { NSWorkspace.shared.open(url) } label: { Label(L("git.dictionary.documentation"), systemImage: Symbols.openInBrowser) }
                            .buttonStyle(.bordered).help(L("git.dictionary.documentationHelp"))
                            .accessibilityIdentifier("git.dictionary.documentation")
                    }
                    Button { Task { await loadManual() } } label: { Label(L("git.dictionary.manual"), systemImage: Symbols.gitDictionary) }
                        .buttonStyle(.bordered).disabled(loading || capability?.available != true)
                        .help(L("git.dictionary.manualHelp"))
                        .accessibilityIdentifier("git.dictionary.manual")
                    if loading { ProgressView().controlSize(.small) }
                }
                if let manual {
                    Text(verbatim: manual).font(.uiCaption.monospaced()).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("git.dictionary.manualText")
                }
            }
        }
        .formStyle(.grouped).themedScroll()
    }

    private func loadManual() async {
        loading = true
        defer { loading = false }
        do {
            let text: String = try await StackStore.shared.call(["method": "gitHelp", "command": command.name])
            manual = text.trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            let failure = GitFailure(error)
            manual = failure.detail.isEmpty ? failure.title : "\(failure.title). \(failure.detail)"
        }
    }
}
