import AppKit
import SwiftUI

/// The right side of «Nuevo proyecto» while it is a form: a compact header for the kind, what is
/// missing as a notice with its action, and a grouped form with the project, its versions, the
/// options of its kind and what happens when it is created.
extension NewProjectSheet {
    // MARK: Header

    /// The kind's tile, its title and one line; the framework and generator versions in a secondary line.
    var header: some View {
        HStack(alignment: .center, spacing: 12) {
            TechLogo(tech: .of(info.logo), size: 40)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L("new.titleFor"), L("kind.\(kind)"))).font(.uiTitle3.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(L("new.about.\(kind)")).font(.uiCallout).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !packagesLine.isEmpty {
                    Text(packagesLine).font(.uiCaption).foregroundStyle(.tertiary).lineLimit(1).truncationMode(.tail)
                        .accessibilityIdentifier("new.packages")
                }
            }
            .help(features)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6)
    }

    /// "Laravel 13.42.0 · laravel/laravel 13.11.0": what the generator will install.
    var packagesLine: String {
        var parts: [String] = []
        if let framework = info.framework, let version = store.projectVersions[framework.package] { parts.append("\(framework.name) \(version)") }
        if let package = info.generatorPackage, let version = store.projectVersions[package] { parts.append("\(info.generator) \(version)") }
        return parts.joined(separator: " · ")
    }

    /// What the project brings, for the header's help.
    var features: String {
        String(format: L("new.includesHelp"), (1...3).map { L("new.feature.\(kind).\($0)") }.joined(separator: " · "))
    }

    // MARK: Form

    var form: some View {
        VStack(spacing: 0) {
            header
            if let missingRuntime {
                Notice(.warning, missingRuntime) {
                    // A missing version installs here, in its language's picker; utilities, on their language's page.
                    Button { if installsHere { installing = true } else { dismiss(); store.route = .language(installLanguage) } } label: {
                        Label(L("new.install"), systemImage: Symbols.install)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("new.install")
                }
                .padding(.horizontal, 20).padding(.top, 8)
            }
            Form {
                projectSection
                versionsSection
                optionsSection
                afterSection
            }
            .formStyle(.grouped)
            .themedScroll()
            .accessibilityIdentifier("new.form")
        }
        .sheet(isPresented: $installing) {
            VersionPickerSheet(store: store, provider: .language(installLanguage, store: store), scope: "new.\(installLanguage)").themedSheet()
        }
    }

    // MARK: Proyecto

    private var serves: Bool { !(info.app || (kind == "rust" && template == "cli")) }

    @ViewBuilder private var projectSection: some View {
        Section {
            TextField(L("common.name"), text: $name, prompt: Text(L("new.namePrompt")))
                .focused($nameFocused)
                .onSubmit { if canCreate { create() } }
                .formField(L("common.name"))
                .accessibilityIdentifier("new.name")
            if let nameProblem {
                Label(nameProblem, systemImage: Symbols.error).foregroundStyle(Brand.danger)
                    .accessibilityIdentifier("new.nameProblem")
            }
            LabeledContent(L("common.address")) {
                if serves {
                    Text(slug.isEmpty ? "—" : address).font(.uiSubheadline.monospaced())
                        .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else {
                    Text(L("new.notASite")).lineLimit(2)
                }
            }
            .accessibilityIdentifier("new.address")
            LabeledContent(L("new.location")) {
                let path = (slug.isEmpty ? parent : target).replacingOccurrences(of: NSHomeDirectory(), with: "~")
                HStack(spacing: 8) {
                    Text(path).font(.uiSubheadline.monospaced()).lineLimit(1).truncationMode(.middle).help(path)
                    Button { choose() } label: { Label(L("common.choose"), systemImage: Symbols.folder) }
                        .buttonStyle(.bordered).accessibilityIdentifier("new.chooseLocation")
                }
            }
            placeRow
        } header: {
            Text(L("new.sectionProject"))
        } footer: {
            Text(L("new.run.\(kind)")).font(.uiCaption).foregroundStyle(.secondary)
                .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                .help(L("new.runs"))
        }
    }

    /// App, Service or Web inside the projects folder, suggested by the kind. A folder chosen by
    /// hand is used as it is: the row says so and offers to go back to the projects folder.
    @ViewBuilder private var placeRow: some View {
        if chosenParent != nil {
            LabeledContent {
                Button { chosenParent = nil } label: { Label(L("new.place.reset"), systemImage: Symbols.reload) }
                    .buttonStyle(.bordered).help(L("new.place.resetHelp")).accessibilityIdentifier("new.place.reset")
            } label: {
                Text(L("common.folder"))
                Text(L("new.place.manual"))
            }
            .accessibilityIdentifier("new.place.manual")
        } else if sortsByPlace {
            Picker(selection: Binding(get: { place }, set: { placeChoice = $0 })) {
                ForEach(ProjectPlace.allCases) { Label($0.title, systemImage: $0.symbol).tag($0) }
            } label: {
                Text(L("common.folder"))
                Text(L("new.place.detail"))
            }
            .pickerStyle(.segmented)
            .help(String(format: L("new.place.help"), suggestedPlace.title))
            .accessibilityIdentifier("new.place")
        }
    }

    // MARK: Versiones

    /// Node.js, the utility the kind needs and Git: what the project will use, each with its version or «Falta».
    private var requirementRows: [(title: String, value: String?)] {
        var rows: [(String, String?)] = []
        if needsNode { rows.append(("Node.js", nodeVersion)) }
        if let tool = info.needsTool, tool != "clt" {
            rows.append((L("tool.\(tool)"), store.devTools[tool].flatMap { $0.installed ? ($0.version ?? "") : nil }))
        }
        if git || info.needsTool == "clt" {
            rows.append((info.needsTool == "clt" ? L("tools.clt") : "Git", store.appleTools ? L("new.ready") : nil))
        }
        return rows
    }

    private var hasLanguagePicker: Bool { kind == "laravel" ? !installedPhp.isEmpty : (needsPython && !installedPython.isEmpty) }

    @ViewBuilder private var versionsSection: some View {
        if hasLanguagePicker || !requirementRows.isEmpty {
            Section(L("new.sectionVersions")) {
                if kind == "laravel" && !installedPhp.isEmpty {
                    VersionChoice(store: store, language: "PHP", detail: L("new.phpDetail"), installed: installedPhp,
                                  requirement: requirement, proposed: proposedPhp, note: frameworkNote("PHP"), selection: $php,
                                  install: { installing = true })
                    frameworkPicker(language: "PHP", chosen: chosenPhp)
                } else if needsPython && !installedPython.isEmpty {
                    VersionChoice(store: store, language: "Python", detail: L("new.pythonDetail"), installed: installedPython,
                                  requirement: requirement, proposed: proposedPython, note: frameworkNote("Python"), selection: $python,
                                  install: { installing = true })
                    frameworkPicker(language: "Python", chosen: chosenPython)
                }
                ForEach(requirementRows, id: \.title) { row in
                    LabeledContent(row.title) {
                        if let value = row.value {
                            Text(value.isEmpty ? L("new.ready") : value).monospacedDigit()
                        } else {
                            Label(L("new.missing"), systemImage: Symbols.warning).foregroundStyle(Brand.warning)
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder private func frameworkPicker(language: String, chosen: String?) -> some View {
        if frameworkVersions.count > 1 {
            FrameworkVersionChoice(kind: kind, language: language, versions: frameworkVersions, chosenLanguage: chosen,
                                   selected: chosenFramework?.cycle, select: { frameworkVersion = $0 })
        }
    }

    // MARK: Opciones del tipo

    @ViewBuilder private var optionsSection: some View {
        switch kind {
        case "laravel":
            Section(L("new.sectionOptions")) {
                optionPicker(L("new.kit"), id: "new.kit", options: ProjectKindInfo.kits, selection: $kit)
                optionPicker(L("new.testing"), id: "new.testing", options: [
                    TemplateOption(id: "pest", title: "Pest", detail: L("new.testing.pest")),
                    TemplateOption(id: "phpunit", title: "PHPUnit", detail: L("new.testing.phpunit")),
                ], selection: $testing, segmented: true)
                optionPicker(L("new.database"), id: "new.database", options: [
                    TemplateOption(id: "sqlite", title: "SQLite", detail: L("new.db.sqlite")),
                    TemplateOption(id: "mysql", title: "MySQL", detail: engineDetail("mysql")),
                    TemplateOption(id: "pgsql", title: "PostgreSQL", detail: engineDetail("postgres")),
                ], selection: $database, segmented: true)
            }
        case "django", "fastapi":
            Section(L("new.sectionOptions")) {
                optionPicker(L("new.manager"), id: "new.manager", options: [
                    TemplateOption(id: "pip", title: "pip + venv", detail: L("new.manager.pip")),
                    TemplateOption(id: "uv", title: "uv", detail: store.devTools["uv"]?.installed == true ? L("new.manager.uv") : L("new.manager.uvMissing")),
                ], selection: $manager, segmented: true)
            }
        case "astro", "emdash", "next", "vite", "rust", "swift", "react-native":
            Section(L("new.sectionOptions")) {
                optionPicker(L("new.template"), id: "new.template", options: templateOptions,
                             selection: Binding(get: { template }, set: { templates[kind] = $0 }), segmented: templateOptions.count <= 3)
                if kind == "emdash" {
                    optionPicker(L("new.platform"), id: "new.platform", options: [
                        TemplateOption(id: "cloudflare", title: "Cloudflare Workers", detail: L("new.platform.cloudflare")),
                        TemplateOption(id: "node", title: "Node.js", detail: L("new.platform.node")),
                    ], selection: $platform, segmented: true)
                }
            }
        default:
            EmptyView()
        }
    }

    /// Exclusive options: segmented when there are a few short ones, a menu otherwise; the chosen
    /// option's detail under the row's title.
    private func optionPicker(_ title: String, id: String, options: [TemplateOption], selection: Binding<String>, segmented: Bool = false) -> some View {
        let detail = options.first { $0.id == selection.wrappedValue }?.detail ?? ""
        let picker = Picker(selection: selection) {
            ForEach(options) { option in
                Text(option.title).tag(option.id).help(option.detail).accessibilityIdentifier("new.option.\(option.id)")
            }
        } label: {
            Text(title)
            Text(detail)
        }
        .accessibilityIdentifier(id)
        return Group {
            if segmented { picker.pickerStyle(.segmented) } else { picker.pickerStyle(.menu) }
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

    // MARK: Al terminar

    private var afterSection: some View {
        Section(L("new.sectionAfter")) {
            if !store.groups.isEmpty {
                Picker(selection: $groupChoice) {
                    Text(L("new.groupNone")).tag("")
                    ForEach(store.groups) { Text($0.name).tag($0.id) }
                } label: {
                    Text(L("common.folder"))
                    Text(L("new.groupDetail"))
                }
                .accessibilityIdentifier("new.groupPicker")
            }
            Toggle(isOn: $git) {
                Text(L("new.git"))
                Text(store.appleTools ? L("new.gitDetail") : L("new.gitMissing"))
            }
            .accessibilityIdentifier("new.git")
        }
    }
}
