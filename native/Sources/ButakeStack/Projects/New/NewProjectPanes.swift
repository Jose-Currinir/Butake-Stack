import AppKit
import SwiftUI

extension NewProjectSheet {
    // MARK: Kotlin Multiplatform and Open

    var wizardPane: some View {
        VStack(spacing: 0) {
            header
            Form {
                Section {
                    ForEach(1...3, id: \.self) { number in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(number).").monospacedDigit().foregroundStyle(.secondary)
                            Text(L("new.kmpStep\(number)")).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } header: {
                    Text(L("new.kmpSteps"))
                } footer: {
                    Text(L("new.kmpWizard")).font(.uiCaption).foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading).frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    HStack(spacing: 10) {
                        Link(destination: URL(string: "https://kmp.jetbrains.com")!) { Label(L("new.kmpOpenWizard"), systemImage: Symbols.openInBrowser) }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("new.kmpOpenWizard")
                        Button { select(.open) } label: { Label(L("new.kmpThenOpen"), systemImage: Symbols.folder) }
                            .buttonStyle(.bordered).accessibilityIdentifier("new.kmpThenOpen")
                        Spacer(minLength: 0)
                    }
                }
            }
            .formStyle(.grouped).themedScroll()
        }
    }

    /// Choosing or dropping a folder; Stack detects what it is.
    var openPane: some View {
        ContentUnavailableView {
            Label(L("new.openTitle"), systemImage: Symbols.newFolder)
        } description: {
            Text(L("new.openDetail")) + Text(verbatim: "\n") + Text(L("new.openDetects"))
        } actions: {
            Button { chooseExisting() } label: { Label(L("new.openChoose"), systemImage: Symbols.folder) }
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("new.openChoose")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay {
            // The system's drop highlight: the accent around the area while a folder is over it.
            if dropping {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Brand.accent, lineWidth: 3).padding(10)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let folder = urls.first(where: { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }) else { return false }
            open(folder.path)
            return true
        } isTargeted: { dropping = $0 }
    }

    /// Cloning a repository: the Git tool's sheet, reached from here too.
    var clonePane: some View {
        ContentUnavailableView {
            Label(L("new.cloneTitle"), systemImage: Symbols.gitClone)
        } description: {
            Text(L("new.cloneDetail"))
        } actions: {
            Button { clone() } label: { Label(L("new.cloneChoose"), systemImage: Symbols.gitClone) }
                .buttonStyle(.borderedProminent).controlSize(.large).accessibilityIdentifier("new.cloneChoose")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        case "astro", "emdash", "next", "vite", "react-native":
            list = [("generator", "npx")]
            if kind == "vite" { list.append(("dependencies", "npm install")) }
        case "django", "fastapi":
            list = manager == "uv" ? [("uvInit", "uv init"), ("dependencies", "uv add")] : [("venv", "python -m venv"), ("dependencies", "pip install")]
            if kind == "django" { list.append(("djangoProject", "startproject")) }
        case "rust":
            list = [("cargoNew", "cargo new")]
            if template != "cli" { list += [("dependencies", "cargo add"), ("compile", "cargo build")] }
        case "swift":
            list = [("swiftPackage", "swift package")]
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

    /// A title for a phase that is not the form: a tile, a title and a line under it.
    func phaseHeader(_ title: String, detail: String, @ViewBuilder tile: () -> some View) -> some View {
        HStack(spacing: 12) {
            tile()
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.uiTitle3.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                Text(detail).font(.uiCallout).foregroundStyle(.secondary).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 6)
    }

    var creatingPane: some View {
        VStack(spacing: 0) {
            TimelineView(.periodic(from: started, by: 1)) { context in
                phaseHeader(String(format: L("new.creatingName"), slug),
                            detail: String(format: L("new.elapsed"), Elapsed.clock(context.date.timeIntervalSince(started)))) {
                    TechLogo(tech: .of(info.logo), size: 40)
                }
            }
            Form {
                StepListSection(steps: steps.map { step in
                    ProgressStep(id: step.key, title: step.key == "generator" ? String(format: L("new.step.generator"), L("kind.\(kind)")) : L("new.step.\(step.key)"))
                }, current: currentStep, scope: "new.step")
                Section { logDisclosure }
            }
            .formStyle(.grouped).themedScroll()
        }
        .task {
            #if DEBUG
            if QAHooks.newPhase != nil { return }
            #endif
            while !Task.isCancelled {
                let lines = await store.stepLog("create-\(slug)")
                if lines != log { log = lines }
                try? await Task.sleep(for: .milliseconds(700))
            }
        }
    }

    var logDisclosure: some View {
        LogDisclosure(lines: log, expanded: $showLog, id: "new.log")
    }

    func donePane(_ created: CreatedProject) -> some View {
        VStack(spacing: 0) {
            phaseHeader(String(format: L("new.doneTitle"), created.name),
                        detail: (created.project?.url?.absoluteString ?? L("new.doneApp")) + " · " + String(format: L("new.doneElapsed"), Elapsed.clock(created.seconds))) {
                IconTile(symbol: Symbols.success, color: Brand.success, size: 40)
            }
            // In one row when they fit; with larger text, one under the other instead of cut.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { doneActions(created); Spacer(minLength: 0) }
                VStack(alignment: .leading, spacing: 8) { doneActions(created) }
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20).padding(.top, 8)
            Form {
                summary(created)
                if !created.notes.isEmpty {
                    Section(L("new.nextSteps")) {
                        ForEach(created.notes, id: \.self) { note in
                            Text(L("note.\(note)")).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                if !log.isEmpty { Section { logDisclosure } }
            }
            .formStyle(.grouped).themedScroll()
        }
    }

    /// What to do with the new project: start it, see it in Finder, the editor or Butake Git.
    @ViewBuilder func doneActions(_ created: CreatedProject) -> some View {
        if let site = created.project {
            Button { Task { await store.setSite(site, enabled: true); finish(created) } } label: { Label(L("new.turnOn"), systemImage: Symbols.start) }
                .buttonStyle(.borderedProminent).fixedSize().accessibilityIdentifier("new.turnOn")
        }
        Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: created.path) } label: { Label(L("menu.showInFinder"), systemImage: Symbols.folder) }
            .buttonStyle(.bordered).fixedSize().accessibilityIdentifier("new.showInFinder")
        Button { Editor.open(created.path) } label: { Label(L("project.openEditor"), systemImage: Symbols.editor) }
            .buttonStyle(.bordered).fixedSize().accessibilityIdentifier("new.openEditor")
        if store.pluginEnabled("git") && FileManager.default.fileExists(atPath: created.path + "/.git") {
            Button { finish(created); GitTool.shared.show(created.path) } label: { Label(L("git.openHere"), systemImage: Symbols.git) }
                .buttonStyle(.bordered).fixedSize().accessibilityIdentifier("new.openGit")
        }
    }

    /// What was created, as the project will run it.
    func summary(_ created: CreatedProject) -> some View {
        let project = created.project
        let choice: String? = switch kind {
        case "laravel": kit == "none" ? nil : ProjectKindInfo.kits.first { $0.id == kit }?.title
        case "astro", "emdash", "next", "vite", "rust", "swift", "react-native": ProjectKindInfo.templates[kind]?.first { $0.id == template }?.title
        default: nil
        }
        let runtime = [project?.php.map { "PHP \($0)" }, project?.node.map { "Node \($0)" }, project?.runtime["python"].map { "Python \($0)" }].compactMap { $0 }.joined(separator: " · ")
        let path = created.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")
        return Section(L("new.created")) {
            InfoRow(title: L("common.type"), value: [L("kind.\(kind)"), choice].compactMap { $0 }.joined(separator: " · "))
            if !runtime.isEmpty { InfoRow(title: L("new.summaryRuntime"), value: runtime) }
            if let port = project?.upstream { InfoRow(title: L("new.summaryPort"), value: "127.0.0.1:\(port)", mono: true) }
            if kind == "laravel" {
                InfoRow(title: L("new.database"), value: ["sqlite": "SQLite", "mysql": "MySQL", "pgsql": "PostgreSQL"][database] ?? database)
            }
            InfoRow(title: L("new.location"), value: path, mono: true)
            if FileManager.default.fileExists(atPath: created.path + "/.git") {
                InfoRow(title: "Git", value: L("new.summaryGit"))
            }
        }
    }

    func failedPane(_ message: String) -> some View {
        VStack(spacing: 0) {
            phaseHeader(L("new.failedTitle"), detail: L("new.failedClean")) {
                IconTile(symbol: Symbols.warning, color: Brand.warning, size: 40)
            }
            Form {
                Section { Text(message).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                if !log.isEmpty { Section { logDisclosure } }
            }
            .formStyle(.grouped).themedScroll()
        }
    }
}
