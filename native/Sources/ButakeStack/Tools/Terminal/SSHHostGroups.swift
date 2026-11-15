import Foundation

/// Groups and tags of the saved hosts. Neither is stored on its own: a group or a tag exists while a
/// host has it, so renaming, merging or deleting one rewrites the hosts that use it (the engine keeps
/// their forwards running: only a change of server, user, key or jump stops them).
extension SSHTerminal {
    /// Hosts in each group ("" is «Sin grupo»).
    func hostCount(group: String) -> Int { hosts.filter { $0.group == group }.count }
    /// Hosts with a tag (ignoring case, like the engine).
    func hostCount(tag: String) -> Int { hosts.filter { $0.has(tag: tag) }.count }

    /// Moves a host to another group ("" takes it out of every group).
    func move(_ id: String, to group: String) async {
        guard var host = host(id), host.group != group else { return }
        host.group = group
        await rewrite([host])
    }

    /// Renames a group; to the name of another group, it merges both.
    func renameGroup(_ group: String, to name: String) async { await rewrite(SSHHost.renaming(group: group, to: name, in: hosts)) }

    /// Its hosts go to «Sin grupo»; no host is deleted.
    func deleteGroup(_ group: String) async { await renameGroup(group, to: "") }

    /// Renames a tag on every host; to the name of another tag, it merges both.
    func renameTag(_ tag: String, to name: String) async { await rewrite(SSHHost.renaming(tag: tag, to: name, in: hosts)) }

    /// Takes a tag off every host.
    func deleteTag(_ tag: String) async { await rewrite(SSHHost.removing(tag: tag, in: hosts)) }

    /// Saves the changed hosts in one request: the engine validates all of them first and writes once,
    /// so a refusal leaves every host as it was.
    private func rewrite(_ changed: [SSHHost]) async {
        guard !changed.isEmpty else { return }
        do { let _: [SSHHost] = try await store.call(["method": "sshUpdateHosts", "hosts": changed.map(encode)]) } catch { store.report(error) }
        await load()
    }
}

extension SSHHost {
    func has(tag: String) -> Bool { tags.contains { $0.lowercased() == tag.lowercased() } }

    /// A new host with the same data, to save under another name (its forwards get new ids).
    func duplicate() -> SSHHost {
        var copy = self
        copy.id = ""
        copy.name = String(format: L("ssh.duplicateName"), name)
        copy.forwards = forwards.map { var forward = $0; forward.id = ""; return forward }
        return copy
    }

    /// A group's name as the engine keeps it: trimmed, up to 60 characters.
    static func cleanGroup(_ name: String) -> String { String(name.trimmingCharacters(in: .whitespaces).prefix(60)) }

    /// Tags as the engine keeps them: trimmed, without commas or repeats (ignoring case), at most 12
    /// of up to 30 characters each.
    static func cleanTags(_ tags: [String]) -> [String] {
        var out: [String] = []
        for tag in tags.map({ String($0.replacingOccurrences(of: ",", with: " ").trimmingCharacters(in: .whitespaces).prefix(30)) }) where !tag.isEmpty {
            if !out.contains(where: { $0.lowercased() == tag.lowercased() }) { out.append(tag) }
        }
        return Array(out.prefix(12))
    }

    /// The hosts of `group` moved to `name` (to another group's name, both merge; "" is «Sin grupo»).
    static func renaming(group: String, to name: String, in hosts: [SSHHost]) -> [SSHHost] {
        let name = cleanGroup(name)
        guard !group.isEmpty, name != group else { return [] }
        return hosts.filter { $0.group == group }.map { var host = $0; host.group = name; return host }
    }

    /// The hosts with `tag`, with it renamed (to another tag's name, both merge into one).
    static func renaming(tag: String, to name: String, in hosts: [SSHHost]) -> [SSHHost] {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty, name != tag else { return [] }
        return hosts.filter { $0.has(tag: tag) }.map { host in
            var host = host
            host.tags = cleanTags(host.tags.map { $0.lowercased() == tag.lowercased() ? name : $0 })
            return host
        }
    }

    /// The hosts with `tag`, without it.
    static func removing(tag: String, in hosts: [SSHHost]) -> [SSHHost] {
        hosts.filter { $0.has(tag: tag) }.map { host in
            var host = host
            host.tags.removeAll { $0.lowercased() == tag.lowercased() }
            return host
        }
    }
}
