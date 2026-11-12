import AppKit
import SwiftUI

/// Project assistant: create a project of any kind the stack serves with its official generator, or
/// open an existing folder. Both end in the same detection, so a created project and an opened one
/// get the same processes, versions and services. Sites are registered off, like every site.
struct NewProjectSheet: View {
    @Bindable var store: StackStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newProject.parent") private var savedParent = ""
    @State private var mode = Mode.create
    @State private var kind = "laravel"
    @State private var name = ""
    @State private var parent = ""
    // Laravel
    @State private var kit = "none"
    @State private var testing = "pest"
    @State private var database = "sqlite"
    // JavaScript generators
    @State private var templates: [String: String] = [:]
    @State private var platform = "cloudflare"
    @State private var git = true
    @State private var creating = false
    @State private var openInGit = ButakeGit.installed
    @State private var log: [String] = []
    @State private var dropping = false

    enum Mode: String { case create, open }

    struct Kind: Identifiable {
        let id: String; let logo: String; let needs: Need
        enum Need { case php, node, none, wizard }
    }
    static let kinds: [Kind] = [
        Kind(id: "laravel", logo: "laravel", needs: .php), Kind(id: "php", logo: "php", needs: .php),
        Kind(id: "astro", logo: "astro", needs: .node), Kind(id: "emdash", logo: "emdash", needs: .node),
        Kind(id: "next", logo: "next", needs: .node), Kind(id: "vite", logo: "vite", needs: .node),
        Kind(id: "node", logo: "node", needs: .node), Kind(id: "static", logo: "static", needs: .none),
        Kind(id: "kmp", logo: "kmp", needs: .wizard),
    ]
    /// Generator templates the engine accepts, in its order (the first is the default).
    static let templateChoices: [String: [String]] = [
        "astro": ["minimal", "basics", "blog", "portfolio", "starlight"],
        "emdash": ["blog", "starter", "marketing", "portfolio"],
        "next": ["app", "api", "empty"],
        "vite": ["react-ts", "vue-ts", "svelte-ts", "solid-ts", "preact-ts", "lit-ts", "vanilla-ts"],
    ]
    let kits: [(String, String, String)] = [
        ("none", "Laravel", "laravel"), ("react", "React", "react"), ("vue", "Vue", "vue"),
        ("svelte", "Svelte", "svelte"), ("livewire", "Livewire", "livewire"),
    ]

    var current: Kind { Self.kinds.first { $0.id == kind } ?? Self.kinds[0] }
    var slug: String {
        name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
            .split(separator: "-").joined(separator: "-")
    }
    var template: String { templates[kind] ?? Self.templateChoices[kind]?.first ?? "" }
    var nodeReady: Bool { !(store.installedTools["node"] ?? []).isEmpty }
    /// What this kind still needs before it can be created, if anything.
    var missing: String? {
        switch current.needs {
        case .php: store.phpReady ? nil : L("new.needsPhp")
        case .node: nodeReady ? nil : L("new.needsNode")
        case .none, .wizard: nil
        }
    }
    var canCreate: Bool { !slug.isEmpty && !creating && missing == nil && current.needs != .wizard && !parent.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                if mode == .create { TechLogo(tech: .of(current.logo), size: 44) } else { IconTile(symbol: "folder", size: 44) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode == .create ? L("new.title") : L("new.openHeading")).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(mode == .create ? L("new.subtitle") : L("new.openSubtitle")).font(.uiCaption).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $mode) {
                    Text(L("new.modeCreate")).tag(Mode.create)
                    Text(L("new.modeOpen")).tag(Mode.open)
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                .disabled(creating).accessibilityIdentifier("new.mode")
            }
            .padding(20)
            Divider()
            Group {
                if mode == .create { createForm } else { openPane }
            }
            .frame(maxHeight: .infinity)
            Divider()
            HStack {
                if creating {
                    ProgressView().controlSize(.small)
                    Text(L("new.creating")).font(.uiCaption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                if mode == .create {
                    Button(L("new.create")) { create() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(!canCreate).accessibilityIdentifier("new.create")
                }
            }
            .padding(14)
        }
        .frame(width: 700, height: 640)
        .interactiveDismissDisabled(creating)
        .onAppear {
            if parent.isEmpty {
                var isDirectory: ObjCBool = false
                parent = FileManager.default.fileExists(atPath: savedParent, isDirectory: &isDirectory) && isDirectory.boolValue ? savedParent : NSHomeDirectory()
            }
        }
        .task { if store.installedTools["node"] == nil { await store.refreshRuntimes() } }
    }

    // MARK: Create

    private var createForm: some View {
        Form {
            Section(L("new.kind")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(Self.kinds) { item in
                        KitTile(title: L("kind.\(item.id)"), tech: .of(item.logo), selected: kind == item.id) { kind = item.id }
                            .accessibilityIdentifier("new.kind.\(item.id)")
                    }
                }
                .padding(.vertical, 4)
                Text(L("new.about.\(kind)")).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if current.needs == .wizard {
                Section {
                    Label(L("new.kmpWizard"), systemImage: "info.circle").fixedSize(horizontal: false, vertical: true)
                    HStack {
                        Link(destination: URL(string: "https://kmp.jetbrains.com")!) { Label(L("new.kmpOpenWizard"), systemImage: "safari") }
                        Spacer()
                        Button(L("new.kmpThenOpen")) { mode = .open }
                    }
                }
            } else {
                Section {
                    TextField(L("new.name"), text: $name, prompt: Text("mi-app")).accessibilityIdentifier("new.name")
                    LabeledContent(L("new.address")) { Text(slug.isEmpty ? "—" : "\(slug).test").foregroundStyle(.secondary) }
                    LabeledContent(L("new.location")) {
                        HStack {
                            Text(parent.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button(L("new.choose")) { choose() }
                        }
                    }
                    if let missing {
                        HStack {
                            Label(missing, systemImage: "exclamationmark.triangle.fill").font(.uiCaption).foregroundStyle(Brand.warning)
                            Spacer()
                            Button(L("new.install")) { dismiss(); store.showSetup = true }.controlSize(.small)
                        }
                    }
                }
                options
                Section {
                    Toggle(L("new.git"), isOn: $git)
                    if git && ButakeGit.installed {
                        Toggle(L("new.openInGit"), isOn: $openInGit).accessibilityIdentifier("new.openInGit")
                    }
                }
            }
        }
        .formStyle(.grouped).themedScroll()
        .disabled(creating)
        .overlay { if creating { progress } }
    }

    @ViewBuilder private var options: some View {
        switch kind {
        case "laravel":
            Section(L("new.kit")) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 5), spacing: 10) {
                    ForEach(kits, id: \.0) { id, title, logo in
                        KitTile(title: title, tech: .of(logo), selected: kit == id) { kit = id }
                    }
                }
                .padding(.vertical, 4)
            }
            Section(L("new.options")) {
                Picker(L("new.testing"), selection: $testing) {
                    Text("Pest").tag("pest"); Text("PHPUnit").tag("phpunit")
                }.pickerStyle(.segmented)
                Picker(L("new.database"), selection: $database) {
                    Text("SQLite").tag("sqlite"); Text("MySQL").tag("mysql"); Text("PostgreSQL").tag("pgsql")
                }.pickerStyle(.segmented)
                if database != "sqlite" && store.engineVersion(database == "mysql" ? "mysql" : "postgres") == nil {
                    Label(L("new.engineMissing"), systemImage: "exclamationmark.triangle.fill").font(.uiCaption).foregroundStyle(Brand.warning)
                }
            }
        case "astro", "emdash", "next", "vite":
            Section(L("new.options")) {
                Picker(L("new.template"), selection: Binding(get: { template }, set: { templates[kind] = $0 })) {
                    ForEach(Self.templateChoices[kind] ?? [], id: \.self) { Text(L("new.template.\(kind).\($0)")).tag($0) }
                }
                .accessibilityIdentifier("new.template")
                if kind == "emdash" {
                    Picker(L("new.platform"), selection: $platform) {
                        Text("Cloudflare").tag("cloudflare"); Text("Node.js").tag("node")
                    }.pickerStyle(.segmented)
                }
            }
        default:
            EmptyView()
        }
    }

    /// The steps this project goes through, in order, with the log line that starts each one.
    var steps: [(key: String, marker: String)] {
        var list: [(String, String)]
        switch kind {
        case "laravel":
            list = [("composer", "create-project")]
            if testing == "pest" { list.append(("tests", "pestphp")) }
            if kit != "none" { list.append(("frontend", "npm")) }
            if database == "sqlite" { list.append(("database", "migrate")) }
        case "astro", "emdash", "next", "vite":
            list = [("generator", "npx")]
            if kind == "vite" { list.append(("dependencies", "npm install")) }
        default:
            list = [("files", "")]
        }
        if git { list.append(("git", "git ")) }
        return list
    }
    /// Index of the step running now, read from the commands logged so far.
    var currentStep: Int {
        let commands = log.filter { $0.hasPrefix("$ ") }
        return steps.indices.last { index in !steps[index].marker.isEmpty && commands.contains { $0.contains(steps[index].marker) } } ?? 0
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("new.creating")).font(.ui(size: 15, weight: .semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 10) {
                    Group {
                        if index < currentStep { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.success) }
                        else if index == currentStep { ProgressView().controlSize(.small) }
                        else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                    }
                    .frame(width: 18)
                    Text(step.key == "generator" ? String(format: L("new.step.generator"), L("kind.\(kind)")) : L("new.step.\(step.key)"))
                        .foregroundStyle(index > currentStep ? .secondary : .primary)
                }
            }
            if let last = log.last(where: { !$0.hasPrefix("$ ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                Text(last).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle)
            }
        }
        .padding(22)
        .frame(width: 420, alignment: .leading)
        .glassCard(radius: 18)
        .shadow(color: .black.opacity(0.2), radius: 20, y: 8)
        .task {
            while !Task.isCancelled {
                log = await store.stepLog("create-\(slug)")
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: Open

    private var openPane: some View {
        VStack(spacing: 18) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: "folder.badge.plus").font(.system(size: 40, weight: .light)).foregroundStyle(Brand.accent)
                Text(L("new.openTitle")).font(.ui(size: 16, weight: .semibold))
                Text(L("new.openDetail")).font(.uiCallout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 460)
                Button(L("new.openChoose")) { chooseExisting() }
                    .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("new.openChoose")
            }
            .padding(30)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(dropping ? Brand.accent : Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .dropDestination(for: URL.self) { urls, _ in
                guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { return false }
                open(folder.path)
                return true
            } isTargeted: { dropping = $0 }
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 9), spacing: 8) {
                ForEach(Self.kinds) { item in TechLogo(tech: .of(item.logo), size: 26).help(L("kind.\(item.id)")) }
            }
            .frame(maxWidth: 420)
            Text(L("new.openDetects")).font(.uiCaption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(24)
    }

    // MARK: Actions

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: parent)
        if panel.runModal() == .OK, let url = panel.url { parent = url.path; savedParent = url.path }
    }
    func chooseExisting() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
        panel.prompt = L("site.chooseFolder")
        if panel.runModal() == .OK, let url = panel.url { open(url.path) }
    }
    /// Detection shows its editor once this sheet is gone (two sheets can't stack).
    func open(_ path: String) {
        dismiss()
        Task {
            try? await Task.sleep(for: .milliseconds(350))
            await store.detect(path)
        }
    }
    func create() {
        creating = true
        var request: [String: Any] = ["kind": kind, "name": slug, "parent": parent, "git": git]
        switch kind {
        case "laravel": request.merge(["kit": kit, "testing": testing, "database": database]) { $1 }
        case "astro", "next", "vite": request["template"] = template
        case "emdash": request.merge(["template": template, "platform": platform]) { $1 }
        default: break
        }
        Task {
            let ok = await store.createProject(request)
            creating = false
            if ok {
                savedParent = parent
                if git && openInGit { ButakeGit.open((parent as NSString).appendingPathComponent(slug)) }
                dismiss()
            }
        }
    }
}

private struct KitTile: View {
    let title: String
    let tech: Tech
    let selected: Bool
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                TechLogo(tech: tech, size: 30).saturation(selected ? 1 : 0.6)
                Text(title).font(.uiCaption.weight(.medium))
            }
            .frame(maxWidth: .infinity).padding(.vertical, 12)
            .foregroundStyle(selected ? Brand.accent : .secondary)
            .background(selected ? Brand.accent.opacity(0.15) : Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Brand.accent : .clear, lineWidth: 1.5))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title).accessibilityAddTraits(selected ? .isSelected : [])
    }
}
