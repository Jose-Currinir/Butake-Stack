import AppKit
import SwiftUI

/// A folder scanned for projects (`scanFolder`).
struct FolderScan: Decodable, Sendable, Identifiable {
    let root: String
    let name: String
    let rootIsProject: Bool
    let projects: [ScannedProject]
    var id: String { root }
}
struct ScannedProject: Decodable, Sendable, Identifiable {
    let group: String
    let web: Bool
    /// What it's built with when Stack doesn't serve it (swift, android, react-native, rust…).
    let tech: String?
    let detection: Detection
    var id: String { detection.project.path }
}

/// Opens a folder that holds several projects: every project found, grouped by the subfolder it lives
/// in, to add at once (off, like every project) and, optionally, sorted into Stack folders.
struct ImportFolderSheet: View {
    let store: StackStore
    let scan: FolderScan
    @State private var selected: Set<String> = []
    @State private var grouping = Grouping.subfolders
    @State private var importing = false
    @State private var done = 0
    /// How many were being added when the import started.
    @State private var toImportCount = 0
    @State private var failures: [String] = []
    /// Keep watching the folder for new projects (offered, never added on their own).
    @State private var watch = false

    enum Grouping: String, CaseIterable, Identifiable { case subfolders, single, none; var id: String { rawValue } }

    var registered: Set<String> { Set(store.projects.map { URL(fileURLWithPath: $0.path).standardizedFileURL.path }) }
    func isRegistered(_ item: ScannedProject) -> Bool { registered.contains(URL(fileURLWithPath: item.detection.project.path).standardizedFileURL.path) }
    var available: [ScannedProject] { scan.projects.filter { !isRegistered($0) } }
    var sections: [(name: String, items: [ScannedProject])] {
        var order: [String] = []
        var byGroup: [String: [ScannedProject]] = [:]
        for item in scan.projects {
            if byGroup[item.group] == nil { order.append(item.group) }
            byGroup[item.group, default: []].append(item)
        }
        return order.map { ($0, byGroup[$0] ?? []) }
    }
    var hasSubfolders: Bool { scan.projects.contains { !$0.group.isEmpty } }

    var body: some View {
        SheetFrame(title: String(format: L("import.title"), scan.name), symbol: Symbols.importFolder,
                   detail: String(format: L("import.summary"), scan.projects.count, scan.projects.filter(\.web).count),
                   width: 680, height: 560,
                   actionTitle: String(format: L("import.add"), toImport.count), actionID: "import.add",
                   canAct: !toImport.isEmpty && !importing, cancelID: importing ? nil : "import.cancel") {
            await importSelected()
        } content: {
            if importing { progress } else { list }
        } status: {
            if !failures.isEmpty {
                Label(String(format: L("import.failed"), failures.joined(separator: ", ")), systemImage: Symbols.warning)
                    .font(.uiCaption).foregroundStyle(Brand.warning).lineLimit(2)
            } else {
                Toggle(L("watch.toggle"), isOn: $watch)
                    .toggleStyle(.checkbox).help(L("watch.toggleHelp")).disabled(importing)
                    .accessibilityIdentifier("import.watch")
                    .onChange(of: watch) { _, on in
                        guard on != store.isWatched(scan.root) else { return }
                        Task { await store.setWatched(scan.root, on) }
                    }
            }
        }
        .interactiveDismissDisabled(importing)
        .task {
            // The list of watched folders may not be loaded yet when the sheet opens.
            if store.watchedFolders.isEmpty { await store.refreshWatched() }
            watch = store.isWatched(scan.root)
        }
        .onAppear {
            selected = Set(available.filter(\.web).map(\.id))
            if !hasSubfolders { grouping = .single }
        }
    }

    /// What gets added: the selection, without what is already in Stack.
    var toImport: [ScannedProject] { scan.projects.filter { selected.contains($0.id) && !isRegistered($0) } }

    private var list: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Menu {
                    Button(L("import.selectWeb")) { selected = Set(available.filter(\.web).map(\.id)) }
                        .accessibilityIdentifier("import.selectWeb")
                    Button(L("import.selectAll")) { selected = Set(available.map(\.id)) }
                        .keyboardShortcut("a").accessibilityIdentifier("import.selectAll")
                    Button(L("import.selectNone")) { selected = [] }
                        .accessibilityIdentifier("import.selectNone")
                } label: {
                    Label(L("import.select"), systemImage: Symbols.selected)
                }
                .fixedSize().accessibilityIdentifier("import.selectMenu")
                Spacer()
                Picker(L("import.grouping"), selection: $grouping) {
                    if hasSubfolders { Text(L("import.grouping.subfolders")).tag(Grouping.subfolders) }
                    Text(String(format: L("import.grouping.single"), scan.name)).tag(Grouping.single)
                    Text(L("import.grouping.none")).tag(Grouping.none)
                }
                .fixedSize().accessibilityIdentifier("import.grouping")
            }
            // Arrow keys move, ⇧ and ⌘ extend, ⌘A selects everything; the checkbox adds or takes one out.
            List(selection: $selected) {
                ForEach(sections, id: \.name) { section in
                    Section {
                        ForEach(section.items) { item in row(item).tag(item.id).selectionDisabled(isRegistered(item)) }
                    } header: {
                        Text(verbatim: "\(section.name.isEmpty ? scan.name : section.name) · \(section.items.count)")
                    }
                }
            }
            .listStyle(.inset)
            .accessibilityIdentifier("import.list")
            Text(L("import.off")).font(.uiCaption).foregroundStyle(.secondary)
        }
        .frame(minHeight: 260)
    }

    private func row(_ item: ScannedProject) -> some View {
        let project = item.detection.project
        let already = isRegistered(item)
        let taken = !already && store.projects.contains { $0.id == project.id }
        return HStack(spacing: 10) {
            Toggle(URL(fileURLWithPath: project.path).lastPathComponent, isOn: Binding(get: { already || selected.contains(item.id) }, set: { on in
                if on { selected.insert(item.id) } else { selected.remove(item.id) }
            }))
            .toggleStyle(.checkbox).labelsHidden().disabled(already)
            .accessibilityIdentifier("import.row.\(item.id).toggle")
            TechLogo(tech: !item.web && item.tech != nil ? .of(item.tech!) : project.tech, size: 24).opacity(item.web || already ? 1 : 0.6)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: project.path).lastPathComponent).foregroundStyle(already ? .secondary : .primary)
                Text(!item.web && item.tech != nil ? L("tech.\(item.tech!)") : "\(project.tech.title) · \(taken ? uniqueID(project.id) : project.id).test")
                    .font(.uiCaption).foregroundStyle(.secondary)
            }
            Spacer()
            if already { Chip(text: L("import.already"), symbol: Symbols.success, tint: Brand.success) }
            else if taken { Chip(text: L("import.renamed"), symbol: Symbols.renamed, tint: Brand.warning).help(String(format: L("import.renamedHelp"), project.id, uniqueID(project.id))) }
            else if !item.web { Chip(text: L(item.tech == nil ? "import.notWeb" : "import.notSite"), symbol: item.tech == nil ? "questionmark.circle" : "hammer") }
        }
        .padding(.vertical, 2)
        .accessibilityIdentifier("import.row.\(project.id)")
    }

    private var progress: some View {
        VStack(spacing: 14) {
            ProgressView(value: Double(done), total: Double(max(toImportCount, 1))).frame(maxWidth: 320)
            Text(String(format: L("import.progress"), done, toImportCount)).font(.uiCallout.monospacedDigit()).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 260)
    }

    /// The folder's id, or the first free one with a number (gestion → gestion-2).
    func uniqueID(_ id: String, reserved: Set<String> = []) -> String {
        let used = Set(store.projects.map(\.id)).union(reserved)
        guard used.contains(id) else { return id }
        var n = 2
        while used.contains("\(id)-\(n)") { n += 1 }
        return "\(id)-\(n)"
    }

    /// Adds the selection; true when everything was added and the sheet can close.
    func importSelected() async -> Bool {
        let items = toImport
        toImportCount = items.count
        withAnimation(.smooth) { importing = true }
        done = 0; failures = []
        var reserved: Set<String> = []
        var placed: [String: [String]] = [:]
        for item in items {
            var project = item.detection.project
            let id = uniqueID(project.id, reserved: reserved)
            if id != project.id {
                let tld = project.domain.split(separator: ".").last.map(String.init) ?? "test"
                project.id = id; project.domains = ["\(id).\(tld)"]
            }
            reserved.insert(id)
            do {
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(project))
                let saved: Project = try await store.call(["method": "saveProject", "project": object])
                let group = switch grouping { case .subfolders: item.group.isEmpty ? scan.name : item.group; case .single: scan.name; case .none: "" }
                if !group.isEmpty { placed[group, default: []].append(saved.id) }
            } catch {
                failures.append(URL(fileURLWithPath: project.path).lastPathComponent)
            }
            withAnimation(.snappy) { done += 1 }
        }
        await store.refresh()
        // Into an existing Stack folder of the same name, or a new one.
        for (name, ids) in placed.sorted(by: { $0.key < $1.key }) {
            if let existing = store.groups.first(where: { $0.name.compare(name, options: .caseInsensitive) == .orderedSame }) {
                for id in ids { store.move(id, to: existing.id) }
            } else {
                store.createGroup(named: name, with: ids)
            }
        }
        // Watched folder: what was left unmarked is not offered again.
        if watch {
            let skipped = available.filter { !selected.contains($0.id) }.map(\.detection.project.path)
            await store.ignoreWatched(scan.root, paths: skipped)
        }
        let added = items.count - failures.count
        if added > 0 { store.notify(String(format: L("import.done"), added)) }
        if failures.isEmpty { return true }
        withAnimation(.smooth) { importing = false }
        return false
    }
}
