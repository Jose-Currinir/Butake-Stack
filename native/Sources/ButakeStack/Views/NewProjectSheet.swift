import AppKit
import SwiftUI

/// New Laravel project with the official installer's choices, run with the stack's own PHP,
/// Composer and Node. The site is registered off, like every site.
struct NewProjectSheet: View {
    @Bindable var store: StackStore
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var parent: String = NewProjectSheet.defaultParent()
    @State private var kit = "none"
    @State private var testing = "pest"
    @State private var database = "sqlite"
    @State private var git = true
    @State private var creating = false
    @State private var openInGit = ButakeGit.installed
    @State private var log: [String] = []

    static func defaultParent() -> String {
        if let path = StackStore.shared.projects.first?.path { return (path as NSString).deletingLastPathComponent }
        return NSHomeDirectory()
    }
    var slug: String {
        name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
            .split(separator: "-").joined(separator: "-")
    }
    let kits: [(String, String, String)] = [
        ("none", "Laravel", "laravel"), ("react", "React", "react"), ("vue", "Vue", "vue"),
        ("svelte", "Svelte", "svelte"), ("livewire", "Livewire", "livewire"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TechLogo(tech: .of("laravel"), size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(L("new.title")).font(.system(size: 20, weight: .bold, design: .rounded))
                    Text(L("new.subtitle")).font(.uiCaption).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)
            Divider()
            Form {
                Section {
                    TextField(L("new.name"), text: $name, prompt: Text("mi-app")).accessibilityIdentifier("new.name")
                    LabeledContent(L("new.address")) { Text(slug.isEmpty ? "—" : "http://\(slug).test").foregroundStyle(.secondary) }
                    LabeledContent(L("new.location")) {
                        HStack {
                            Text(parent.replacingOccurrences(of: NSHomeDirectory(), with: "~")).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button(L("new.choose")) { choose() }
                        }
                    }
                }
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
                    Toggle(L("new.git"), isOn: $git)
                    if git && ButakeGit.installed {
                        Toggle(L("new.openInGit"), isOn: $openInGit).accessibilityIdentifier("new.openInGit")
                    }
                }
            }
            .formStyle(.grouped).themedScroll()
            .disabled(creating)
            .overlay { if creating { progress } }
            Divider()
            HStack {
                if creating {
                    ProgressView().controlSize(.small)
                    Text(L("new.creating")).font(.uiCaption).foregroundStyle(.secondary)
                }
                Spacer()
                Button(L("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(creating)
                Button(L("new.create")) { create() }
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(slug.isEmpty || creating).accessibilityIdentifier("new.create")
            }
            .padding(14)
        }
        .frame(width: 640, height: 660)
        .interactiveDismissDisabled(creating)
    }

    /// The steps this project goes through, in order, with the log line that starts each one.
    var steps: [(key: String, marker: String)] {
        var list = [("composer", "create-project")]
        if testing == "pest" { list.append(("tests", "pestphp")) }
        if kit != "none" { list.append(("frontend", "npm")) }
        if database == "sqlite" { list.append(("database", "migrate")) }
        if git { list.append(("git", "git ")) }
        return list
    }
    /// Index of the step running now, read from the commands logged so far.
    var current: Int {
        let commands = log.filter { $0.hasPrefix("$ ") }
        return steps.indices.last { index in commands.contains { $0.contains(steps[index].marker) } } ?? 0
    }
    private var progress: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("new.creating")).font(.ui(size: 15, weight: .semibold))
            ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                HStack(spacing: 10) {
                    Group {
                        if index < current { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.success) }
                        else if index == current { ProgressView().controlSize(.small) }
                        else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                    }
                    .frame(width: 18)
                    Text(L("new.step.\(step.key)")).foregroundStyle(index > current ? .secondary : .primary)
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
    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: parent)
        if panel.runModal() == .OK, let url = panel.url { parent = url.path }
    }
    func create() {
        creating = true
        Task {
            let ok = await store.createLaravel(name: slug, parent: parent, kit: kit, testing: testing, database: database, git: git)
            creating = false
            if ok {
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
