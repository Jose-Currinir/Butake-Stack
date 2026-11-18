import Foundation

/// A `.env` dropped on Entornos as an environment: the name proposed from the file, and what goes
/// where (keys and plain values to the store, secret values to the Keychain, never to the screen).
@MainActor enum EnvDrop {
    struct Target: Equatable {
        let id: String
        let name: String
        let kind: EnvKind
    }

    /// What is left of the file's name once `.env` is taken out: `.env.staging` is «staging»,
    /// `production.env` is «production», `.env` alone is empty.
    static func stem(of fileName: String) -> String {
        if fileName.hasPrefix(".env.") { return String(fileName.dropFirst(5)) }
        if fileName.hasSuffix(".env"), fileName != ".env" { return String(fileName.dropLast(4)) }
        return ""
    }

    /// The environment a name becomes: a standard one when the name is a standard environment that
    /// does not exist yet; otherwise a custom one. A taken name gets «2», «3»… until it is free, so a
    /// dropped file never replaces or merges into an environment that exists.
    static func target(_ proposed: String, taken: Set<String>, fallback: String) -> Target {
        let base = proposed.trimmingCharacters(in: .whitespaces).isEmpty ? fallback : proposed.trimmingCharacters(in: .whitespaces)
        var name = base
        var number = 2
        while true {
            let id = StackStore.slug(name)
            if !id.isEmpty, !taken.contains(id) {
                let kind = EnvKind.allCases.first { $0.standard == id } ?? .other
                return Target(id: id, name: name, kind: kind)
            }
            name = "\(base) \(number)"
            number += 1
        }
    }

    /// The entries of the new environment and the secret values for the Keychain.
    static func entries(_ pairs: [(String, String)], secret: [Bool]) -> (entries: [EnvEntry], secrets: [String: String]) {
        var entries: [EnvEntry] = []
        var secrets: [String: String] = [:]
        for (index, pair) in pairs.enumerated() {
            let isSecret = secret.indices.contains(index) ? secret[index] : true
            if isSecret { secrets[pair.0] = pair.1 }
            entries.append(EnvEntry(key: pair.0, value: isSecret ? "" : pair.1, secret: isSecret))
        }
        return (entries, secrets)
    }
}

/// What the confirmation shows of a dropped file: names only, never values.
struct EnvDropPreview: Identifiable {
    let id = UUID()
    let url: URL
    let keys: [String]
    let proposedName: String
}

extension StackStore {
    /// The dropped file's variables as (key, value) pairs, or nil with a message.
    private func readDroppedEnv(_ url: URL) -> [(String, String)]? {
        guard EnvImportFile.accepts(url), let text = try? String(contentsOf: url, encoding: .utf8) else {
            errorMessage = L("env.drop.invalid")
            return nil
        }
        let pairs = DotEnv.parse(text)
        guard !pairs.isEmpty else { errorMessage = L("env.drop.empty"); return nil }
        return pairs
    }

    /// The preview for a file dropped on a project that has environments: variable names only.
    func envDropPreview(_ project: Project, url: URL) -> EnvDropPreview? {
        guard let pairs = readDroppedEnv(url) else { return nil }
        let taken = Set(envs[project.id]?.site.environments.map(\.id) ?? [])
        let proposed = EnvDrop.target(EnvDrop.stem(of: url.lastPathComponent), taken: taken, fallback: L("env.drop.defaultName"))
        return EnvDropPreview(url: url, keys: pairs.map(\.0), proposedName: proposed.name)
    }

    /// Writes an imported environment: secrets to the Keychain first, then keys and plain values.
    private func commitImport(_ project: Project, _ target: EnvDrop.Target, pairs: [(String, String)], activate: Bool) async -> Bool {
        let split = EnvDrop.entries(pairs, secret: await classify(pairs.map(\.0)))
        guard await updateSecrets(project.id, target.id, set: split.secrets) else { return false }
        var site = envs[project.id]?.site ?? ProjectEnvironments(active: nil, environments: [])
        let environment = EnvEnvironment(id: target.id, name: target.name, kind: target.kind, entries: split.entries)
        if activate {
            site.environments.removeAll { $0.id == target.id }
            site.environments.insert(environment, at: 0)
            site.active = target.id
        } else {
            site.environments.append(environment)
        }
        guard await saveEnvs(project.id, site) else { return false }
        await envAudit(project.id, env: target.id, action: "importar")
        notify(activate ? L("env.imported") : String(format: L("env.drop.imported"), target.name))
        return true
    }

    /// A `.env` dropped on a project with no environments becomes its «Local», the same way
    /// «Importar» does with the project's own `.env`: secrets go to the Keychain, nothing is lost (R8).
    func importEnvFile(_ project: Project, from url: URL) async -> Bool {
        guard let pairs = readDroppedEnv(url) else { return false }
        return await commitImport(project, EnvDrop.Target(id: "local", name: L("env.kind.local"), kind: .local), pairs: pairs, activate: true)
    }

    /// A `.env` dropped on a project that has environments becomes a NEW one with the given name
    /// (a taken name gets a number). Never replaces or mixes with an existing environment; it is not
    /// activated. Returns its id.
    func importEnvAsNew(_ project: Project, from url: URL, name: String) async -> String? {
        guard let pairs = readDroppedEnv(url) else { return nil }
        let taken = Set(envs[project.id]?.site.environments.map(\.id) ?? [])
        let target = EnvDrop.target(name, taken: taken, fallback: L("env.drop.defaultName"))
        return await commitImport(project, target, pairs: pairs, activate: false) ? target.id : nil
    }
}
