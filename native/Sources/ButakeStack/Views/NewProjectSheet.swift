import AppKit
import SwiftUI

/// Project assistant. A sidebar of project kinds (and "open an existing folder"); each kind shows
/// what it needs, its templates and options, and creates the project with its official generator
/// and the stack's own PHP, Composer and Node. Creating shows each step live, and ends in a summary
/// with what to do next; a failure says why and keeps the log. Created and opened projects go
/// through the same detection. Sites are registered off, like every site.
struct NewProjectSheet: View {
    @Bindable var store: StackStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage("newProject.parent") private var savedParent = ""
    @AppStorage("newProject.kind") private var savedKind = "laravel"
    @State private var selection: Selection = .kind("laravel")
    @State private var name = ""
    @State private var parent = ""
    @State private var kit = "none"
    @State private var testing = "pest"
    @State private var database = "sqlite"
    @State private var templates: [String: String] = [:]
    @State private var platform = "cloudflare"
    @State private var git = true
    @AppStorage("newProject.group") private var groupChoice = ""
    @State private var openInGit = ButakeGit.installed
    @State private var phase: Phase = .form
    @State private var log: [String] = []
    @State private var started = Date()
    @State private var showLog = false
    @State private var dropping = false
    @FocusState private var nameFocused: Bool

    enum Selection: Hashable { case kind(String), open }
    enum Phase { case form, creating, done(CreatedProject), failed(String) }

    var kind: String { if case .kind(let id) = selection { id } else { "" } }
    var info: ProjectKindInfo { ProjectKindInfo.of(kind) }
    var slug: String {
        name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }.reduce(into: "") { $0.append($1) }
            .split(separator: "-").joined(separator: "-")
    }
    var template: String { templates[kind] ?? ProjectKindInfo.templates[kind]?.first?.id ?? "" }
    var target: String { (parent as NSString).appendingPathComponent(slug) }
    var address: String { "\(info.proxied ? "https" : "http")://\(slug).test" }

    // MARK: Requirements and validation

    var phpVersion: String? { store.phpRuntimes.filter(\.installed).map(\.series).sorted().last }
    var nodeVersion: String? { (store.installedTools["node"] ?? []).map(\.version).sorted { $0.compare($1, options: .numeric) == .orderedDescending }.first }
    var needsNode: Bool { info.needsNode || (kind == "laravel" && kit != "none") }
    var missingRuntime: String? {
        if info.needsPhp && phpVersion == nil { return L("new.needsPhp") }
        if needsNode && nodeVersion == nil { return L("new.needsNode") }
        return nil
    }
    /// What's wrong with the name, if anything: checked as the user types.
    var nameProblem: String? {
        if slug.isEmpty { return nil }
        if slug.count > 40 { return L("new.problem.long") }
        if FileManager.default.fileExists(atPath: target) { return L("new.problem.folder") }
        if store.projects.contains(where: { $0.id == slug }) || store.missingSites.contains(where: { $0.id == slug }) { return L("new.problem.site") }
        return nil
    }
    var canCreate: Bool { !slug.isEmpty && nameProblem == nil && missingRuntime == nil && !parent.isEmpty && !info.wizard }

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                footer
            }
        }
        .frame(width: 880, height: 640)
        .interactiveDismissDisabled(isCreating)
        .onAppear {
            if parent.isEmpty {
                var isDirectory: ObjCBool = false
                parent = FileManager.default.fileExists(atPath: savedParent, isDirectory: &isDirectory) && isDirectory.boolValue ? savedParent : NSHomeDirectory()
            }
            if ProjectKindInfo.all.contains(where: { $0.id == savedKind }) { selection = .kind(savedKind) }
            nameFocused = true
        }
        .onChange(of: selection) { _, new in if case .kind(let id) = new { savedKind = id } }
        .task {
            if store.installedTools["node"] == nil { await store.refreshRuntimes() }
            if store.projectVersions.isEmpty { await store.loadProjectVersions() }
        }
    }

    var isCreating: Bool { if case .creating = phase { true } else { false } }
    var isForm: Bool { if case .form = phase { true } else { false } }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L("new.sidebarTitle")).font(.ui(size: 15, weight: .bold)).padding(.horizontal, 10).padding(.bottom, 8)
            ForEach(ProjectKindInfo.groups, id: \.self) { group in
                Text(L("new.group.\(group)")).font(.ui(size: 10.5, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.top, 10).padding(.bottom, 3)
                ForEach(ProjectKindInfo.all.filter { $0.group == group }) { item in
                    SidebarRow(selected: selection == .kind(item.id)) {
                        TechLogo(tech: .of(item.logo), size: 22)
                    } label: {
                        Text(L("kind.\(item.id)"))
                    } action: { select(.kind(item.id)) }
                    .accessibilityIdentifier("new.kind.\(item.id)")
                }
            }
            Spacer(minLength: 12)
            Divider().padding(.bottom, 6)
            SidebarRow(selected: selection == .open) {
                IconTile(symbol: "folder", size: 22)
            } label: {
                Text(L("new.modeOpen"))
            } action: { select(.open) }
            .accessibilityIdentifier("new.mode.open")
        }
        .padding(12)
        .frame(width: 210)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.primary.opacity(0.03))
        .disabled(!isForm)
    }

    private func select(_ new: Selection) {
        withAnimation(.snappy(duration: 0.25)) { selection = new }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        switch phase {
        case .form:
            Group {
                if selection == .open { openPane } else if info.wizard { wizardPane } else { form }
            }
            .id(selection)
            .transition(.asymmetric(insertion: .opacity.combined(with: .offset(y: 8)), removal: .opacity))
        case .creating:
            creatingPane.transition(.opacity.combined(with: .scale(scale: 0.98)))
        case .done(let created):
            donePane(created).transition(.opacity.combined(with: .scale(scale: 0.98)))
        case .failed(let message):
            failedPane(message).transition(.opacity)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            TechLogo(tech: .of(info.logo), size: 52)
            VStack(alignment: .leading, spacing: 5) {
                Text(String(format: L("new.titleFor"), L("kind.\(kind)"))).font(.system(size: 21, weight: .bold, design: .rounded))
                Text(L("new.about.\(kind)")).font(.uiCallout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let framework = info.framework, let version = store.projectVersions[framework.package] {
                        Chip(text: "\(framework.name) \(version)", symbol: "sparkles", tint: Brand.accent)
                    }
                    Chip(text: info.generatorPackage.flatMap { store.projectVersions[$0] }.map { "\(info.generator) \($0)" } ?? info.generator, symbol: "shippingbox")
                    if info.needsPhp { requirement(phpVersion.map { "PHP \($0)" }, missing: "PHP") }
                    if needsNode { requirement(nodeVersion.map { "Node \($0.split(separator: ".").first ?? "")" }, missing: "Node.js") }
                    if git { requirement(store.appleTools ? "Git" : nil, missing: "Git") }
                }
                .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
    }

    /// What the project brings and how Stack runs it.
    private var details: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 7) {
                Text(L("new.includes")).font(.ui(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                ForEach(1...3, id: \.self) { index in
                    Label(L("new.feature.\(kind).\(index)"), systemImage: "checkmark").font(.uiCaption)
                        .labelStyle(TightLabel())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider().padding(.horizontal, 14)
            VStack(alignment: .leading, spacing: 7) {
                Text(L("new.runs")).font(.ui(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                Text(L("new.run.\(kind)")).font(.uiCaption).fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
    }

    private func requirement(_ ready: String?, missing: String) -> some View {
        Chip(text: ready ?? String(format: L("new.chipMissing"), missing), symbol: ready == nil ? "exclamationmark.triangle.fill" : "checkmark", tint: ready == nil ? Brand.warning : Brand.success)
    }

    private var form: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                details
                if let missingRuntime {
                    Banner(symbol: "exclamationmark.triangle.fill", tint: Brand.warning, text: missingRuntime) {
                        Button(L("new.install")) { dismiss(); store.showSetup = true }.controlSize(.small)
                    }
                }
                section(L("new.sectionProject")) {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("", text: $name, prompt: Text("mi-app"))
                            .textFieldStyle(.plain)
                            .font(.system(size: 22, weight: .semibold, design: .rounded))
                            .focused($nameFocused)
                            .onSubmit { if canCreate { create() } }
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
                            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(nameProblem == nil ? (nameFocused ? Brand.accent.opacity(0.7) : .clear) : Brand.danger, lineWidth: 1.5))
                            .accessibilityIdentifier("new.name")
                        if let nameProblem {
                            Label(nameProblem, systemImage: "xmark.octagon.fill").font(.uiCaption).foregroundStyle(Brand.danger)
                                .transition(.opacity.combined(with: .move(edge: .top)))
                        }
                        VStack(spacing: 0) {
                            PreviewRow(symbol: "globe", title: L("new.address"), value: slug.isEmpty ? "—" : address)
                            Divider().padding(.leading, 34)
                            PreviewRow(symbol: "folder", title: L("new.location"), value: (slug.isEmpty ? parent : target).replacingOccurrences(of: NSHomeDirectory(), with: "~")) {
                                Button(L("new.choose")) { choose() }.controlSize(.small)
                            }
                        }
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
                    }
                    .animation(.snappy(duration: 0.2), value: nameProblem)
                }
                options
                section(L("new.sectionAfter")) {
                    VStack(spacing: 0) {
                        if !store.groups.isEmpty {
                            HStack(spacing: 10) {
                                Image(systemName: "folder").foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(L("new.group")).font(.uiCallout)
                                    Text(L("new.groupDetail")).font(.uiCaption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Picker("", selection: $groupChoice) {
                                    Text(L("new.groupNone")).tag("")
                                    ForEach(store.groups) { Text($0.name).tag($0.id) }
                                }
                                .labelsHidden().fixedSize().accessibilityIdentifier("new.groupPicker")
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            Divider().padding(.leading, 34)
                        }
                        ToggleRow(symbol: "arrow.triangle.branch", title: L("new.git"), detail: store.appleTools ? L("new.gitDetail") : L("new.gitMissing"), isOn: $git)
                        if git && ButakeGit.installed {
                            Divider().padding(.leading, 34)
                            ToggleRow(symbol: "arrow.up.forward.app", title: L("new.openInGit"), detail: L("new.openInGitDetail"), isOn: $openInGit)
                                .accessibilityIdentifier("new.openInGit")
                        }
                    }
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
                }
            }
            .padding(24)
        }
        .themedScroll()
    }

    @ViewBuilder private var options: some View {
        switch kind {
        case "laravel":
            section(L("new.kit")) {
                OptionGrid(columns: 3, options: ProjectKindInfo.kits, selection: $kit)
            }
            section(L("new.testing")) {
                OptionGrid(columns: 2, options: [
                    TemplateOption(id: "pest", title: "Pest", detail: L("new.testing.pest"), symbol: "checkmark.seal"),
                    TemplateOption(id: "phpunit", title: "PHPUnit", detail: L("new.testing.phpunit"), symbol: "checklist"),
                ], selection: $testing)
            }
            section(L("new.database")) {
                OptionGrid(columns: 3, options: [
                    TemplateOption(id: "sqlite", title: "SQLite", detail: L("new.db.sqlite"), symbol: "doc"),
                    TemplateOption(id: "mysql", title: "MySQL", detail: engineDetail("mysql"), logo: "mysql"),
                    TemplateOption(id: "pgsql", title: "PostgreSQL", detail: engineDetail("postgres"), logo: "postgres"),
                ], selection: $database)
            }
        case "astro", "emdash", "next", "vite":
            section(L("new.template")) {
                OptionGrid(columns: kind == "vite" ? 4 : 3, options: templateOptions,
                           selection: Binding(get: { template }, set: { templates[kind] = $0 }))
            }
            if kind == "emdash" {
                section(L("new.platform")) {
                    OptionGrid(columns: 2, options: [
                        TemplateOption(id: "cloudflare", title: "Cloudflare Workers", detail: L("new.platform.cloudflare"), logo: "emdash"),
                        TemplateOption(id: "node", title: "Node.js", detail: L("new.platform.node"), logo: "node"),
                    ], selection: $platform)
                }
            }
        default:
            EmptyView()
        }
    }

    /// Templates, with the framework version where it's known (Vite's frameworks).
    private var templateOptions: [TemplateOption] {
        (ProjectKindInfo.templates[kind] ?? []).map { option in
            guard kind == "vite", let package = ["react-ts": "react", "vue-ts": "vue", "svelte-ts": "svelte"][option.id],
                  let version = store.projectVersions[package] else { return option }
            return TemplateOption(id: option.id, title: option.title, detail: "\(option.detail) · \(option.title) \(version)", symbol: option.symbol, logo: option.logo)
        }
    }

    /// What will happen with this engine's database, given its state right now.
    private func engineDetail(_ engine: String) -> String {
        if store.engineVersion(engine) == nil { return L("new.db.notInstalled") }
        return store.phase("stack.\(engine)") == .running ? L("new.db.running") : L("new.db.off")
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.ui(size: 12, weight: .semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: Kotlin Multiplatform and Open

    private var wizardPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                Text(L("new.kmpWizard")).font(.uiCallout).fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 14) {
                    StepRow(number: 1, text: L("new.kmpStep1"))
                    StepRow(number: 2, text: L("new.kmpStep2"))
                    StepRow(number: 3, text: L("new.kmpStep3"))
                }
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
                HStack(spacing: 10) {
                    Link(destination: URL(string: "https://kmp.jetbrains.com")!) { Label(L("new.kmpOpenWizard"), systemImage: "safari") }
                        .buttonStyle(.borderedProminent)
                    Button { select(.open) } label: { Label(L("new.kmpThenOpen"), systemImage: "folder") }
                }
            }
            .padding(24)
        }
        .themedScroll()
    }

    private var openPane: some View {
        VStack(spacing: 18) {
            Spacer()
            VStack(spacing: 14) {
                Image(systemName: dropping ? "folder.fill.badge.plus" : "folder.badge.plus")
                    .font(.system(size: 46, weight: .light)).foregroundStyle(Brand.accent)
                    .symbolEffect(.bounce, value: dropping)
                    .contentTransition(.symbolEffect(.replace))
                Text(L("new.openTitle")).font(.system(size: 19, weight: .bold, design: .rounded))
                Text(L("new.openDetail")).font(.uiCallout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 440)
                Button(L("new.openChoose")) { chooseExisting() }
                    .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("new.openChoose")
            }
            .padding(34)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(dropping ? Brand.accent.opacity(0.08) : .clear))
            .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(dropping ? Brand.accent : Color.primary.opacity(0.15), style: StrokeStyle(lineWidth: 1.5, dash: [7, 5])))
            .scaleEffect(dropping ? 1.015 : 1)
            .animation(.spring(duration: 0.3), value: dropping)
            .dropDestination(for: URL.self) { urls, _ in
                guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { return false }
                open(folder.path)
                return true
            } isTargeted: { dropping = $0 }
            HStack(spacing: 10) {
                ForEach(ProjectKindInfo.all) { item in TechLogo(tech: .of(item.logo), size: 24).help(L("kind.\(item.id)")) }
            }
            Text(L("new.openDetects")).font(.uiCaption).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(28)
    }

    // MARK: Creating, done, failed

    /// The steps this project goes through, in order, with the log line that starts each one.
    var steps: [(key: String, marker: String)] {
        var list: [(String, String)]
        switch kind {
        case "laravel":
            list = [("composer", "create-project")]
            if testing == "pest" { list.append(("tests", "pestphp")) }
            list.append(("frontend", "npm install"))
            list.append(("database", "artisan migrate"))
        case "astro", "emdash", "next", "vite":
            list = [("generator", "npx")]
            if kind == "vite" { list.append(("dependencies", "npm install")) }
        default:
            list = [("files", "")]
        }
        if git { list.append(("git", "git init")) }
        return list
    }
    var currentStep: Int {
        let commands = log.filter { $0.hasPrefix("$ ") }
        return steps.indices.last { index in !steps[index].marker.isEmpty && commands.contains { $0.contains(steps[index].marker) } } ?? 0
    }

    private var creatingPane: some View {
        VStack(spacing: 0) {
            VStack(spacing: 22) {
                ZStack {
                    Circle().stroke(Color.primary.opacity(0.08), lineWidth: 4).frame(width: 84, height: 84)
                    Circle().trim(from: 0, to: CGFloat(currentStep + 1) / CGFloat(max(steps.count, 1)))
                        .stroke(Brand.accent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                        .rotationEffect(.degrees(-90)).frame(width: 84, height: 84)
                        .animation(.smooth(duration: 0.5), value: currentStep)
                    TechLogo(tech: .of(info.logo), size: 46)
                }
                VStack(spacing: 4) {
                    Text(String(format: L("new.creatingName"), slug)).font(.system(size: 19, weight: .bold, design: .rounded))
                    TimelineView(.periodic(from: started, by: 1)) { context in
                        Text(String(format: L("new.elapsed"), Self.clock(context.date.timeIntervalSince(started))))
                            .font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
                VStack(alignment: .leading, spacing: 11) {
                    ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                        HStack(spacing: 10) {
                            Group {
                                if index < currentStep { Image(systemName: "checkmark.circle.fill").foregroundStyle(Brand.success).transition(.scale.combined(with: .opacity)) }
                                else if index == currentStep { ProgressView().controlSize(.small) }
                                else { Image(systemName: "circle").foregroundStyle(.tertiary) }
                            }
                            .frame(width: 18)
                            Text(step.key == "generator" ? String(format: L("new.step.generator"), L("kind.\(kind)")) : L("new.step.\(step.key)"))
                                .foregroundStyle(index > currentStep ? .secondary : .primary)
                                .fontWeight(index == currentStep ? .semibold : .regular)
                        }
                        .animation(.snappy, value: currentStep)
                    }
                }
                .frame(width: 360, alignment: .leading)
            }
            .padding(.top, 34)
            Spacer(minLength: 14)
            logDisclosure
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
        .task {
            while !Task.isCancelled {
                let lines = await store.stepLog("create-\(slug)")
                if lines != log { log = lines }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    private var logDisclosure: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                withAnimation(.snappy) { showLog.toggle() }
            } label: {
                Label(showLog ? L("new.hideLog") : L("new.showLog"), systemImage: "chevron.right")
                    .labelStyle(DisclosureLabel(open: showLog))
            }
            .buttonStyle(.plain).font(.uiCaption.weight(.medium)).foregroundStyle(.secondary)
            if showLog {
                LogConsole(lines: log).frame(height: 150).transition(.opacity.combined(with: .move(edge: .bottom)))
            } else if let last = log.last(where: { !$0.hasPrefix("$ ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                Text(last).font(.system(size: 11, design: .monospaced)).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func donePane(_ created: CreatedProject) -> some View {
        ScrollView {
            VStack(spacing: 20) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 56)).foregroundStyle(Brand.success)
                    .symbolEffect(.bounce, options: .nonRepeating)
                    .padding(.top, 26)
                VStack(spacing: 4) {
                    Text(String(format: L("new.doneTitle"), created.project.name)).font(.system(size: 21, weight: .bold, design: .rounded))
                    Text(created.project.url?.absoluteString ?? "").font(.uiCallout).foregroundStyle(.secondary).textSelection(.enabled)
                    Text(String(format: L("new.doneElapsed"), Self.clock(created.seconds))).font(.uiCaption).foregroundStyle(.tertiary)
                }
                HStack(spacing: 10) {
                    ActionTile(symbol: "power", title: L("new.turnOn"), prominent: true) {
                        Task { await store.setSite(created.project, enabled: true); finish(created) }
                    }
                    ActionTile(symbol: "folder", title: L("site.finder")) {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: created.project.path)
                    }
                    ActionTile(symbol: "chevron.left.forwardslash.chevron.right", title: L("site.editor")) { Editor.open(created.project.path) }
                    if ButakeGit.installed && FileManager.default.fileExists(atPath: created.project.path + "/.git") {
                        ActionTile(symbol: "arrow.triangle.branch", title: "Butake Git") { ButakeGit.open(created.project.path) }
                    }
                }
                .frame(maxWidth: 560)
                summary(created.project)
                if !created.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L("new.nextSteps")).font(.ui(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                        ForEach(created.notes, id: \.self) { note in
                            Label(L("note.\(note)"), systemImage: "lightbulb").font(.uiCallout).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: 560, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.04)))
                }
            }
            .frame(maxWidth: .infinity)
            .padding(24)
        }
        .themedScroll()
    }

    /// What was created, as the site will run it.
    private func summary(_ project: Project) -> some View {
        let choice: String? = switch kind {
        case "laravel": kit == "none" ? nil : ProjectKindInfo.kits.first { $0.id == kit }?.title
        case "astro", "emdash", "next", "vite": ProjectKindInfo.templates[kind]?.first { $0.id == template }?.title
        default: nil
        }
        let runtime = [project.php.map { "PHP \($0)" }, project.node.map { "Node \($0)" }].compactMap { $0 }.joined(separator: " · ")
        return VStack(spacing: 0) {
            PreviewRow(symbol: "square.stack.3d.up", title: L("new.summaryKind"), value: [L("kind.\(kind)"), choice].compactMap { $0 }.joined(separator: " · "), mono: false)
            Divider().padding(.leading, 34)
            if !runtime.isEmpty {
                PreviewRow(symbol: "cpu", title: L("new.summaryRuntime"), value: runtime, mono: false)
                Divider().padding(.leading, 34)
            }
            if let port = project.upstream {
                PreviewRow(symbol: "network", title: L("new.summaryPort"), value: "127.0.0.1:\(port)")
                Divider().padding(.leading, 34)
            }
            if kind == "laravel" {
                PreviewRow(symbol: "cylinder", title: L("new.database"), value: ["sqlite": "SQLite", "mysql": "MySQL", "pgsql": "PostgreSQL"][database] ?? database, mono: false)
                Divider().padding(.leading, 34)
            }
            PreviewRow(symbol: "folder", title: L("new.location"), value: project.path.replacingOccurrences(of: NSHomeDirectory(), with: "~"))
            if FileManager.default.fileExists(atPath: project.path + "/.git") {
                Divider().padding(.leading, 34)
                PreviewRow(symbol: "arrow.triangle.branch", title: "Git", value: L("new.summaryGit"), mono: false)
            }
        }
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.035)))
        .frame(maxWidth: 560)
    }

    private func failedPane(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 46)).foregroundStyle(Brand.warning)
                .symbolEffect(.bounce, options: .nonRepeating)
                .padding(.top, 30)
            Text(L("new.failedTitle")).font(.system(size: 20, weight: .bold, design: .rounded))
            Text(message).font(.uiCallout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true).frame(maxWidth: 460)
            Text(L("new.failedClean")).font(.uiCaption).foregroundStyle(.tertiary)
            if !log.isEmpty {
                LogConsole(lines: log).frame(maxHeight: 220)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 10) {
            switch phase {
            case .form:
                if selection != .open && !info.wizard && !slug.isEmpty && nameProblem == nil {
                    Text(String(format: L("new.summary"), L("kind.\(kind)"), target.replacingOccurrences(of: NSHomeDirectory(), with: "~")))
                        .font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Button(L("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                if selection != .open && !info.wizard {
                    Button(L("new.create")) { create() }
                        .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                        .disabled(!canCreate).accessibilityIdentifier("new.create")
                }
            case .creating:
                Text(L("new.creatingHint")).font(.uiCaption).foregroundStyle(.secondary)
                Spacer()
            case .done(let created):
                Button(L("new.another")) { reset() }
                Spacer()
                Button(L("new.goToSite")) { finish(created) }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            case .failed:
                Button(L("new.back")) { withAnimation(.snappy) { phase = .form } }
                Spacer()
                Button(L("action.cancel")) { dismiss() }.keyboardShortcut(.cancelAction)
                Button(L("new.retry")) { create() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
    }

    // MARK: Actions

    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: parent)
        panel.prompt = L("new.choosePrompt")
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
            await store.openFolder(path)
        }
    }
    func create() {
        var request: [String: Any] = ["kind": kind, "name": slug, "parent": parent, "git": git]
        switch kind {
        case "laravel": request.merge(["kit": kit, "testing": testing, "database": database]) { $1 }
        case "astro", "next", "vite": request["template"] = template
        case "emdash": request.merge(["template": template, "platform": platform]) { $1 }
        default: break
        }
        log = []
        started = Date()
        withAnimation(.smooth(duration: 0.35)) { phase = .creating }
        Task {
            let result = await store.createProject(request)
            log = await store.stepLog("create-\(slug)")
            withAnimation(.smooth(duration: 0.35)) {
                switch result {
                case .success(var created):
                    created.seconds = Date().timeIntervalSince(started)
                    savedParent = parent
                    if store.groups.contains(where: { $0.id == groupChoice }) { store.move(created.project.id, to: groupChoice) }
                    // QA windows never drive the user's own Butake Git (its recents are theirs).
                    if git && openInGit && !StackStore.qaWindow { ButakeGit.open(created.project.path) }
                    phase = .done(created)
                case .failure(let failure):
                    phase = .failed(failure.message)
                }
            }
        }
    }
    func finish(_ created: CreatedProject) {
        store.openSite(created.project.id)
        dismiss()
    }
    func reset() {
        name = ""
        log = []
        withAnimation(.snappy) { phase = .form }
        nameFocused = true
    }
}

/// A created project and the next steps the engine noted.
struct CreatedProject: Decodable, Sendable {
    var project: Project
    var notes: [String]
    var seconds: TimeInterval = 0
    enum CodingKeys: String, CodingKey { case project, notes }
}

// MARK: Catalog

struct TemplateOption: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    var symbol: String? = nil
    var logo: String? = nil
}

/// Kinds of project the assistant creates, grouped as the sidebar shows them.
struct ProjectKindInfo: Identifiable {
    let id: String
    let logo: String
    let group: String
    let generator: String
    var needsPhp = false
    var needsNode = false
    var proxied = false
    var wizard = false

    /// Framework shown with its current version, and the generator's package.
    var framework: (name: String, package: String)? {
        switch id {
        case "laravel": ("Laravel", "laravel/framework")
        case "astro": ("Astro", "astro")
        case "emdash": ("EmDash", "emdash")
        case "next": ("Next.js", "next")
        case "vite": ("Vite", "vite")
        default: nil
        }
    }
    var generatorPackage: String? {
        switch id {
        case "laravel": "laravel/laravel"
        case "astro", "emdash", "next", "vite": generator
        default: nil
        }
    }

    static let groups = ["php", "javascript", "other"]
    static let all: [ProjectKindInfo] = [
        ProjectKindInfo(id: "laravel", logo: "laravel", group: "php", generator: "laravel/laravel", needsPhp: true),
        ProjectKindInfo(id: "php", logo: "php", group: "php", generator: "index.php"),
        ProjectKindInfo(id: "astro", logo: "astro", group: "javascript", generator: "create-astro", needsNode: true, proxied: true),
        ProjectKindInfo(id: "emdash", logo: "emdash", group: "javascript", generator: "create-emdash", needsNode: true, proxied: true),
        ProjectKindInfo(id: "next", logo: "next", group: "javascript", generator: "create-next-app", needsNode: true, proxied: true),
        ProjectKindInfo(id: "vite", logo: "vite", group: "javascript", generator: "create-vite", needsNode: true, proxied: true),
        ProjectKindInfo(id: "node", logo: "node", group: "javascript", generator: "node:http", needsNode: true, proxied: true),
        ProjectKindInfo(id: "static", logo: "static", group: "other", generator: "index.html"),
        ProjectKindInfo(id: "kmp", logo: "kmp", group: "other", generator: "kmp.jetbrains.com", proxied: true, wizard: true),
    ]
    static func of(_ id: String) -> ProjectKindInfo { all.first { $0.id == id } ?? all[0] }

    static let kits: [TemplateOption] = [
        TemplateOption(id: "none", title: "Laravel", detail: L("new.kitDetail.none"), logo: "laravel"),
        TemplateOption(id: "react", title: "React", detail: L("new.kitDetail.react"), logo: "react"),
        TemplateOption(id: "vue", title: "Vue", detail: L("new.kitDetail.vue"), logo: "vue"),
        TemplateOption(id: "svelte", title: "Svelte", detail: L("new.kitDetail.svelte"), logo: "svelte"),
        TemplateOption(id: "livewire", title: "Livewire", detail: L("new.kitDetail.livewire"), logo: "livewire"),
    ]
    /// Generator templates the engine accepts, in its order (the first is the default).
    static let templates: [String: [TemplateOption]] = [
        "astro": ["minimal", "basics", "blog", "portfolio", "starlight"].map { option("astro", $0, symbols: ["minimal": "square.dashed", "basics": "square.grid.2x2", "blog": "text.book.closed", "portfolio": "photo.on.rectangle", "starlight": "books.vertical"]) },
        "emdash": ["blog", "starter", "marketing", "portfolio"].map { option("emdash", $0, symbols: ["blog": "text.book.closed", "starter": "sparkles", "marketing": "megaphone", "portfolio": "photo.on.rectangle"]) },
        "next": ["app", "api", "empty"].map { option("next", $0, symbols: ["app": "macwindow", "api": "point.3.connected.trianglepath.dotted", "empty": "square.dashed"]) },
        "vite": [
            TemplateOption(id: "react-ts", title: "React", detail: L("new.template.vite.detail"), logo: "react"),
            TemplateOption(id: "vue-ts", title: "Vue", detail: L("new.template.vite.detail"), logo: "vue"),
            TemplateOption(id: "svelte-ts", title: "Svelte", detail: L("new.template.vite.detail"), logo: "svelte"),
            TemplateOption(id: "solid-ts", title: "Solid", detail: L("new.template.vite.detail"), symbol: "cube"),
            TemplateOption(id: "preact-ts", title: "Preact", detail: L("new.template.vite.detail"), symbol: "atom"),
            TemplateOption(id: "lit-ts", title: "Lit", detail: L("new.template.vite.detail"), symbol: "flame"),
            TemplateOption(id: "vanilla-ts", title: L("new.template.vite.vanilla-ts"), detail: L("new.template.vite.detail"), symbol: "chevron.left.forwardslash.chevron.right"),
        ],
    ]
    private static func option(_ kind: String, _ id: String, symbols: [String: String]) -> TemplateOption {
        TemplateOption(id: id, title: L("new.template.\(kind).\(id)"), detail: L("new.templateDetail.\(kind).\(id)"), symbol: symbols[id])
    }
}

// MARK: Pieces

private struct SidebarRow<Icon: View, Label: View>: View {
    let selected: Bool
    @ViewBuilder let icon: Icon
    @ViewBuilder let label: Label
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                icon
                label.font(.ui(size: 13, weight: selected ? .semibold : .regular)).lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(selected ? Brand.accent.opacity(0.16) : (hovering ? Color.primary.opacity(0.06) : .clear)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Brand.accent : .primary)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// Selectable cards: icon or logo, title and one line of detail.
private struct OptionGrid: View {
    let columns: Int
    let options: [TemplateOption]
    @Binding var selection: String
    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10, alignment: .top), count: columns), spacing: 10) {
            ForEach(options) { option in
                OptionCard(option: option, selected: selection == option.id) {
                    withAnimation(.snappy(duration: 0.2)) { selection = option.id }
                }
            }
        }
    }
}

private struct OptionCard: View {
    let option: TemplateOption
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    if let logo = option.logo { TechLogo(tech: .of(logo), size: 26) }
                    else if let symbol = option.symbol { IconTile(symbol: symbol, tint: selected ? Brand.accent : .secondary, size: 26) }
                    Spacer()
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15)).foregroundStyle(selected ? Brand.accent : Color.secondary.opacity(0.4))
                        .contentTransition(.symbolEffect(.replace))
                }
                Text(option.title).font(.ui(size: 13, weight: .semibold)).foregroundStyle(.primary)
                Text(option.detail).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(selected ? Brand.accent.opacity(0.09) : Color.primary.opacity(hovering ? 0.06 : 0.035)))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(selected ? Brand.accent : Color.primary.opacity(0.06), lineWidth: selected ? 1.5 : 1))
            .scaleEffect(hovering && !selected ? 1.01 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .accessibilityLabel(option.title).accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("new.option.\(option.id)")
    }
}

private struct PreviewRow<Trailing: View>: View {
    let symbol: String
    let title: String
    let value: String
    var mono = true
    @ViewBuilder var trailing: Trailing
    init(symbol: String, title: String, value: String, mono: Bool = true, @ViewBuilder trailing: () -> Trailing = { EmptyView() }) {
        self.symbol = symbol; self.title = title; self.value = value; self.mono = mono; self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            Text(title).font(.uiCallout)
            Spacer(minLength: 12)
            Text(value).font(mono ? .uiCallout.monospaced() : .uiCallout).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                .contentTransition(.opacity)
            trailing
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

private struct ToggleRow: View {
    let symbol: String
    let title: String
    let detail: String
    @Binding var isOn: Bool
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.uiCallout)
                Text(detail).font(.uiCaption).foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("", isOn: $isOn).toggleStyle(.switch).labelsHidden().controlSize(.small)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
    }
}

private struct Banner<Trailing: View>: View {
    let symbol: String
    let tint: Color
    let text: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.uiCallout).fixedSize(horizontal: false, vertical: true)
            Spacer()
            trailing
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(tint.opacity(0.1)))
    }
}

private struct StepRow: View {
    let number: Int
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.ui(size: 12, weight: .bold)).foregroundStyle(Brand.accent)
                .frame(width: 24, height: 24).background(Circle().fill(Brand.accent.opacity(0.14)))
            Text(text).font(.uiCallout).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
        }
    }
}

private struct ActionTile: View {
    let symbol: String
    let title: String
    var prominent = false
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: symbol).font(.system(size: 18, weight: .semibold))
                Text(title).font(.uiCaption.weight(.medium)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 14)
            .foregroundStyle(prominent ? Color.white : Color.primary)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(prominent ? Brand.accent : Color.primary.opacity(hovering ? 0.08 : 0.05)))
            .scaleEffect(hovering ? 1.02 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
    }
}

private struct LogConsole: View {
    let lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(line.hasPrefix("$ ") ? Brand.accent : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
                .textSelection(.enabled)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
        }
    }
}

private struct DisclosureLabel: LabelStyle {
    let open: Bool
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.rotationEffect(.degrees(open ? 90 : 0)).font(.system(size: 9, weight: .bold))
            configuration.title
        }
    }
}

private struct TightLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            configuration.icon.font(.system(size: 9, weight: .bold)).foregroundStyle(Brand.success)
            configuration.title
        }
    }
}
