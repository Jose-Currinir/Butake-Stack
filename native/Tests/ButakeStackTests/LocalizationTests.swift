import ButakeDesign
import Foundation
import Testing
@testable import ButakeStack

/// Keys built at run time ("kind.\(kind)", "vault.kind.\(kind)"…) are invisible to a literal search:
/// every family the interface composes must have a text for each value it can take.
@MainActor @Test func everyDynamicFamilyHasItsTexts() async throws {
    var keys: [String] = []
    func family(_ pattern: String, _ values: some Sequence<String>) {
        keys += values.map { pattern.replacingOccurrences(of: "*", with: $0) }
    }

    // Routes, the service categories of the sidebar and the tabs of Ajustes.
    keys += ["route.home", "route.sites", "route.utilities"]
    let categories = Route.services
    family("settings.tab.*", SettingsTab.allCases.map(\.rawValue))
    family("category.*", categories)
    family("tech.short.*", Tech.shortForms)
    family("language.*.versionsFooter", Route.languages)
    // The terminal's link of each language with versions of Stack (LanguageOptionsSection).
    family("terminal.footer.*", ["php", "node", "jdk", "python"])
    family("terminal.confirmDetail.*", ["php", "node", "jdk", "python"])
    // Moving the data folder: how a run can end, where a path lives, what the plan finds.
    family("migration.error.*", DataMigrationSheet.errorCodes)
    family("migration.place.*", DataMigrationSheet.places)
    family("migration.state.*", ["done", "nothing", "resume", "conflict"])

    // Tools: the engine's catalog and the developer utilities of each kind of work.
    let catalog: [ToolInfo] = try await StackEngine().call(["method": "pluginCatalog"])
    #expect(!catalog.isEmpty)
    for tool in catalog {
        family("plugin.*.title", [tool.id])
        family("plugin.*.summary", [tool.id])
        family("plugin.*.row", [tool.id])
        family("plugin.*.deleteDataDetail", [tool.id])
    }
    let devTools = Set(WorkProfile.all.flatMap(\.tools)).union(["uv", "python"])
    family("tool.*", devTools)
    family("toolDetail.*", devTools)
    // Utilities Stack installs itself (engine/src/runtimes/utilities/devtools/mod.rs) say where they come from; every
    // other utility a row can show is installed by Stack's own page, Apple's installer or its official page.
    family("toolSource.*", DevToolInstaller.automatic)
    for tool in devTools where !DevToolInstaller.automatic.contains(tool) && !UtilityCatalog.all.contains(tool) {
        #expect(DevToolInstaller.languages[tool] != nil || tool == "clt" || DevToolSource.pages[tool] != nil, "\(tool) has no way to be installed")
    }
    // Utilidades: each section, and each utility's name, line, source, place and maker's site.
    family("utilities.section.*", UtilityCatalog.groups.map(\.id))
    for family_ in ["tool.*", "toolDetail.*", "toolSource.*", "utilities.place.*"] { family(family_, UtilityCatalog.all) }
    for tool in UtilityCatalog.all { #expect(UtilityCatalog.site(tool) != nil, "\(tool) has no site") }
    family("profile.*", WorkProfile.all.map(\.id))
    family("profile.*.detail", WorkProfile.all.map(\.id))
    family("category.work.*", WorkProfile.categories)

    // Project kinds and what the new-project sheet says of each one.
    let kinds = ProjectKindInfo.all.map(\.id)
    family("kind.*", kinds + ["proxy"])
    family("new.about.*", kinds)
    family("new.run.*", kinds)
    for index in 1...3 { family("new.feature.*.\(index)", kinds) }
    family("new.group.*", ProjectKindInfo.all.map(\.group))
    family("place.*", ProjectPlace.allCases.map(\.rawValue))
    family("tech.*", ["swift", "android", "react-native", "kmp", "rust", "python"])
    // Notes the engine writes when it detects or creates a project (engine/src/web).
    family("note.*", ["dev_script_not_a_server", "emdash_secrets_in_dev_vars", "kmp_database_external", "node_no_script",
                      "app_url_differs", "git_unavailable", "git_failed", "git_no_commit", "kit_uses_pest",
                      "frontend_needs_node", "database_pending_mysql", "database_pending_postgres", "rust_port",
                      "swift_xcode_apps", "rn_pods"])

    // States, tabs and environments.
    family("state.*", ProcessPhase.allCases.map(\.rawValue))
    family("stackState.*", StackState.allCases.map(\.rawValue))
    family("site.tab.*", ProjectPage.Tab.allCases.map(\.rawValue))
    family("env.kind.*", EnvKind.allCases.map(\.rawValue))
    family("env.kindDetail.*", EnvKind.allCases.map(\.rawValue))
    family("env.section.*", EnvSection.allCases.map(\.rawValue))
    // The audit of Entornos (engine/src/web/projects/envs/mod.rs, `audit`).
    family("env.action.*", ["guardar", "activar", "eliminar", "revelar", "copiar", "importar", "exportar", "mover", "actualizar", "renombrar"])
    family("themeSlot.*", ThemeStore.Slot.allCases.map(\.rawValue))
    family("xdebug.mode.*", XdebugRow.modes)
    family("assistant.promise.*", ["0", "1", "2"])

    // Vault.
    family("vault.kind.*", VaultItemKind.allCases.map(\.rawValue))
    family("vault.link.reason.*", VaultImportLink.Reason.allCases.map(\.rawValue))
    family("vault.part.*", VaultSection.allCases.map(\.rawValue) + ["none", "content"])
    family("vault.retired.*", VaultItemKind.allCases.filter(\.isRetired).map(\.rawValue))
    family("vault.import.retired.*", VaultItemKind.allCases.filter(\.isRetired).map(\.rawValue))
    family("vault.importSummary.*", VaultImportSummary.Category.allCases.map(\.rawValue))
    family("vault.importSummary.why.*", VaultImportSummary.Category.allCases.map(\.rawValue))
    family("vault.summary.reason.*", VaultImportSummary.reasons)
    // Registros: its origins and levels.
    family("logs.origin.*", LogOrigin.allCases.map(\.rawValue))
    family("logs.level.*", LogLevel.allCases.map(\.rawValue))
    family("vault.field.*", VaultField.Role.allCases.map(\.rawValue))
    family("vault.filter.*", VaultSession.ExpiryFilter.allCases.map(\.rawValue))
    family("vault.action.*", VaultAccessEntry.Action.allCases.map(\.rawValue))
    family("vault.profileType.*", ["development", "adhoc", "appstore", "enterprise"])
    family("vault.signing.status.*", VaultSigning.Status.allCases.map(\.key))
    family("vault.signing.count.*", VaultSigning.Status.allCases.map(\.key))
    family("vault.import.excluded.*", VaultBackupLayout.Exclusion.allCases.map(\.rawValue))
    family("vault.import.companion.*", ["password", "credentials", "fastlane", "value"])
    family("vault.download.layout.*", VaultFolder.Layout.allCases.map(\.rawValue))

    // Install steps as the engine plans them (engine/src/core/progress.rs, `installSteps`).
    // Every install of the app is followed: utilities (from their page or their row), versions of
    // languages and services, PHP packages and toolchains.
    let followed = UtilityCatalog.all + DevToolInstaller.automatic.sorted()
        + ["python", "node", "jdk", "caddy", "php", "php-package", "rust-toolchain", "swift-toolchain"]
    for tool in followed {
        let steps: [String] = (try? await StackEngine().call(["method": "installSteps", "tool": tool])) ?? []
        #expect(!steps.isEmpty, "\(tool) has no steps")
        family("progress.step.*", steps)
    }
    for tool in Route.allEngines {
        guard let steps: [String] = try? await StackEngine().call(["method": "installSteps", "tool": tool]) else { continue }
        family("progress.step.*", steps)
    }
    // Plans that depend on what this Mac has (rustup, the Android SDK): every step that cannot be cut.
    family("progress.step.*", InstallMonitor.external)
    // Utilities installed from their row elsewhere open the same sheet: it says where each one goes.
    family("utilities.place.*", DevToolInstaller.automatic)

    // AWS: the kinds of credential and the list's sections.
    family("aws.kind.*", AWSProfile.Kind.allCases.map(\.rawValue))
    family("aws.section.*", AWSProfile.Kind.allCases.map(\.rawValue))
    // Google Cloud: the kinds of account, the list's sections and the pages of Google's consoles.
    family("gcp.kind.*", GCPAccount.Kind.allCases.map(\.rawValue))
    family("gcp.section.*", GCPAccount.Kind.allCases.map(\.rawValue))
    family("gcp.console.*", GCPConsolePage.allCases.map(\.rawValue))
    keys.append("tool.gcloud")
    // Skills: the templates, the findings of Salud with their fixes, and why a link is skipped.
    family("skills.template.*", SkillTemplate.allCases.map(\.rawValue))
    family("skills.template.*.detail", SkillTemplate.allCases.map(\.rawValue))
    family("skills.problem.*", SkillProblem.Kind.allCases.map(\.rawValue))
    family("skills.problem.*.detail", SkillProblem.Kind.allCases.map(\.rawValue))
    family("skills.fix.*", ["no_description", "unused", "broken_link", "duplicate_name", "missing_folder", "agent_path", "reveal"])
    family("skills.links.reason.*", ["exists", "export_only"])

    // Every error the engine may name (PUBLIC_ERRORS in engine/src/main.rs) and the database client's own.
    let main = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../../engine/src/main.rs")
    let source = try String(contentsOf: main, encoding: .utf8)
    let list = try #require(source.range(of: "const PUBLIC_ERRORS: &[&str] = &[").flatMap { start in
        source[start.upperBound...].range(of: "];").map { source[start.upperBound..<$0.lowerBound] }
    })
    let codes = list.split(separator: "\"").enumerated().filter { $0.offset % 2 == 1 }.map { String($0.element) }
    #expect(codes.count > 50)
    family("error.*", codes)
    family("error.*", DBProblem.engineCodes)

    let missing = keys.filter { localized($0) == nil }
    #expect(missing.isEmpty, "Missing texts: \(missing.joined(separator: ", "))")
}
