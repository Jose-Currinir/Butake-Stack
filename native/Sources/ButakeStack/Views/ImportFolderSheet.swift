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
    let detection: Detection
    var id: String { detection.project.path }
}

/// Opens a folder that holds several projects: every project found, grouped by the subfolder it lives
/// in, to add at once (off, like every site) and, optionally, sorted into Stack folders.
struct ImportFolderSheet: View {
    let store: StackStore
    let scan: FolderScan
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var grouping = Grouping.subfolders
    @State private var importing = false
    @State private var done = 0
    @State private var failures: [String] = []

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
        VStack(spacing: 0) {
            header
            Divider()
            if importing { progress } else { list }
            Divider()
            footer
        }
        .frame(width: 720, height: 640)
        .interactiveDismissDisabled(importing)
        .onAppear {
            selected = Set(available.filter(\.web).map(\.id))
            if !hasSubfolders { grouping = .single }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            IconTile(symbol: "folder.fill", size: 46)
            VStack(alignment: .leading, spacing: 3) {
                Text(String(format: L("import.title"), scan.name)).font(.system(size: 20, weight: .bold, design: .rounded))
                Text(scan.root.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.uiCaption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(String(format: L("import.summary"), scan.projects.count, scan.projects.filter(\.web).count)).font(.uiCaption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(20)
    }

    private var list: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(L("import.select")).font(.uiCaption).foregroundStyle(.secondary)
                Button(L("import.selectWeb")) { withAnimation(.snappy) { selected = Set(available.filter(\.web).map(\.id)) } }
                Button(L("import.selectAll")) { withAnimation(.snappy) { selected = Set(available.map(\.id)) } }
                Button(L("import.selectNone")) { withAnimation(.snappy) { selected = [] } }
                Spacer()
                Picker(L("import.grouping"), selection: $grouping) {
                    if hasSubfolders { Text(L("import.grouping.subfolders")).tag(Grouping.subfolders) }
                    Text(String(format: L("import.grouping.single"), scan.name)).tag(Grouping.single)
                    Text(L("import.grouping.none")).tag(Grouping.none)
                }
                .fixedSize().accessibilityIdentifier("import.grouping")
            }
            .controlSize(.small)
            .padding(.horizontal, 20).padding(.vertical, 10)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(sections, id: \.name) { section in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label(section.name.isEmpty ? scan.name : section.name, systemImage: "folder.fill")
                                    .font(.ui(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                                Text("\(section.items.count)").font(.ui(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                                    .padding(.horizontal, 6).padding(.vertical, 1).background(Color.primary.opacity(0.07), in: Capsule())
                                Spacer()
                                let ids = section.items.filter { !isRegistered($0) }.map(\.id)
                                if !ids.isEmpty {
                                    let all = ids.allSatisfy(selected.contains)
                                    Button(all ? L("import.selectNone") : L("import.selectAll")) {
                                        withAnimation(.snappy) { if all { selected.subtract(ids) } else { selected.formUnion(ids) } }
                                    }
                                    .buttonStyle(.borderless).controlSize(.small)
                                }
                            }
                            .padding(.horizontal, 4)
                            VStack(spacing: 0) {
                                ForEach(Array(section.items.enumerated()), id: \.element.id) { index, item in
                                    if index > 0 { Divider().padding(.leading, 74) }
                                    row(item).padding(.horizontal, 12).padding(.vertical, 6)
                                }
                            }
                            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
            }
            .themedScroll()
        }
    }

    private func row(_ item: ScannedProject) -> some View {
        let project = item.detection.project
        let already = isRegistered(item)
        let taken = !already && store.projects.contains { $0.id == project.id }
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(get: { selected.contains(item.id) }, set: { on in
                withAnimation(.snappy(duration: 0.15)) { if on { selected.insert(item.id) } else { selected.remove(item.id) } }
            }))
            .toggleStyle(.checkbox).labelsHidden().disabled(already)
            TechLogo(tech: project.tech, size: 24).opacity(item.web || already ? 1 : 0.5)
            VStack(alignment: .leading, spacing: 1) {
                Text(URL(fileURLWithPath: project.path).lastPathComponent).font(.uiCallout.weight(.medium)).foregroundStyle(already ? .secondary : .primary)
                Text("\(project.tech.title) · \(taken ? uniqueID(project.id) : project.id).test").font(.uiCaption).foregroundStyle(.secondary)
            }
            Spacer()
            if already { Chip(text: L("import.already"), symbol: "checkmark", tint: Brand.success) }
            else if taken { Chip(text: L("import.renamed"), symbol: "arrow.triangle.swap", tint: Brand.warning).help(String(format: L("import.renamedHelp"), project.id, uniqueID(project.id))) }
            else if !item.web { Chip(text: L("import.notWeb"), symbol: "questionmark.circle") }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture { if !already { withAnimation(.snappy(duration: 0.15)) { if selected.contains(item.id) { selected.remove(item.id) } else { selected.insert(item.id) } } } }
        .accessibilityIdentifier("import.row.\(project.id)")
    }

    private var progress: some View {
        VStack(spacing: 14) {
            Spacer()
            ProgressView(value: Double(done), total: Double(max(selected.count, 1))).frame(width: 320)
            Text(String(format: L("import.progress"), done, selected.count)).font(.uiCallout.monospacedDigit()).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private var footer: some View {
        HStack {
            if !failures.isEmpty {
                Label(String(format: L("import.failed"), failures.joined(separator: ", ")), systemImage: "exclamationmark.triangle.fill")
                    .font(.uiCaption).foregroundStyle(Brand.warning).lineLimit(2)
            } else {
                Text(L("import.off")).font(.uiCaption).foregroundStyle(.secondary)
            }
            Spacer()
            Button(L("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(importing)
            Button(String(format: L("import.add"), selected.count)) { Task { await importSelected() } }
                .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty || importing).accessibilityIdentifier("import.add")
        }
        .padding(14)
    }

    /// The folder's id, or the first free one with a number (gestion → gestion-2).
    func uniqueID(_ id: String, reserved: Set<String> = []) -> String {
        let used = Set(store.projects.map(\.id)).union(store.missingSites.map(\.id)).union(reserved)
        guard used.contains(id) else { return id }
        var n = 2
        while used.contains("\(id)-\(n)") { n += 1 }
        return "\(id)-\(n)"
    }

    func importSelected() async {
        let items = scan.projects.filter { selected.contains($0.id) && !isRegistered($0) }
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
        let added = items.count - failures.count
        if added > 0 { store.notify(String(format: L("import.done"), added)) }
        if failures.isEmpty { dismiss() } else { withAnimation(.smooth) { importing = false } }
    }
}
