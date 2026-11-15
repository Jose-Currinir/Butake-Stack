import Foundation

/// The master backup layout ("3.CLAVES-APPS"), both ways:
///
///     <Nombre app> (<bundle id>)/README.md, android/, ios/, server/, terceros/
///     _SERVICIOS/<servicio>/README.md and its files; each account of it in `<cuenta>/`
///
/// Fields of an item travel next to its file as `<archivo>.datos.txt` (dotenv lines) so a download
/// can be imported back as it was.
enum VaultFolder {
    static let servicesFolder = "_SERVICIOS"
    static let dataSuffix = ".datos.txt"
    static let maximumFileSize = 20 * 1024 * 1024
    static let maximumFiles = 2_000

    // MARK: Download (plain folder)

    enum Source: Equatable { case blob(UUID), text(String) }
    /// Stack's parts (`android/`, `ios/`…), or the layout of a keys backup by platform and stage
    /// (`04-ANDROID/PROD/`, `03-IOS/QA/`…), which «Importar carpeta» reads back the same.
    enum Layout: String, CaseIterable, Identifiable { case stack, backup; var id: String { rawValue } }
    struct Entry: Equatable { var path: String; var source: Source }

    /// Relative directories (always created, so every app shows its four sections) and files.
    static func plan(_ index: VaultIndex, containers: [UUID], layout: Layout = .stack, now: Date = Date()) -> (directories: [String], files: [Entry]) {
        var directories: [String] = []
        var files: [Entry] = []
        for id in containers {
            guard let container = index.container(id) else { continue }
            let base: String
            switch container.kind {
            case .app:
                base = VaultNames.safeFileName(container.folderName)
                directories.append(base)
                directories += VaultSection.allCases.map { "\(base)/\(folder($0, layout))" }
            case .service:
                base = ([servicesFolder] + container.name.split(separator: "/").map { VaultNames.safeFileName(String($0)) }).joined(separator: "/")
                directories.append(base)
            }
            let start = files.count
            var used: Set<String> = ["\(base)/README.md".lowercased()]
            func unique(_ folder: String, _ name: String) -> String {
                let clean = VaultNames.safeFileName(name)
                var candidate = "\(folder)/\(clean)"
                var counter = 2
                while used.contains(candidate.lowercased()) {
                    let ext = (clean as NSString).pathExtension
                    let stem = ext.isEmpty ? clean : String(clean.dropLast(ext.count + 1))
                    candidate = "\(folder)/\(stem) (\(counter))" + (ext.isEmpty ? "" : ".\(ext)")
                    counter += 1
                }
                used.insert(candidate.lowercased())
                return candidate
            }
            let items = index.items(in: id).sorted { ($0.section?.rawValue ?? "", $0.name) < ($1.section?.rawValue ?? "", $1.name) }
            for item in items {
                let folder = container.kind == .app ? (item.section.map { section in
                    ([base, self.folder(section, layout)] + (layout == .backup ? [VaultBackupLayout.environmentFolder(item.environment)].compactMap { $0 } : [])).joined(separator: "/")
                } ?? base) : ([base] + (item.account?.split(separator: "/").map { VaultNames.safeFileName(String($0)) } ?? [])).joined(separator: "/")
                var anchor = item.name
                for file in item.files {
                    let path = unique(folder, file.name)
                    if file == item.files.first { anchor = (path as NSString).lastPathComponent }
                    files.append(Entry(path: path, source: .blob(file.id)))
                }
                if item.files.isEmpty && item.kind == .note {
                    let name = item.name.lowercased().hasSuffix(".md") ? item.name : item.name + ".md"
                    files.append(Entry(path: unique(folder, name), source: .text(item.notes)))
                } else if !item.fields.isEmpty || !item.notes.isEmpty {
                    files.append(Entry(path: unique(folder, anchor + dataSuffix), source: .text(dataFile(item))))
                }
            }
            files.insert(Entry(path: "\(base)/README.md", source: .text(readme(container, items: items, now: now))), at: start)
        }
        return (directories, files)
    }

    static func folder(_ section: VaultSection, _ layout: Layout) -> String {
        layout == .stack ? section.rawValue : VaultBackupLayout.platformFolder(section)
    }

    /// What there is and which variables to set, never values.
    static func readme(_ container: VaultContainer, items: [VaultItem], now: Date = Date()) -> String {
        let date = Format.fileStamp(now)
        var out = "# \(container.folderName)\n\n"
        out += String(format: L("vault.readme.generated"), date) + "\n\n"
        if !container.notes.isEmpty { out += "## \(L("vault.readme.notes"))\n\n\(container.notes)\n\n" }
        let groups: [(String, [VaultItem])] = container.kind == .app
            ? [(L("vault.readme.general"), items.filter { $0.section == nil })] + VaultSection.allCases.map { section in (section.rawValue, items.filter { $0.section == section }) }
            : [(L("vault.readme.content"), items)]
        for (title, list) in groups where !list.isEmpty {
            out += "## \(title)\n\n"
            for item in list {
                var line = "- **\(item.name)** — \(L("vault.kind.\(item.kind.rawValue)"))"
                if let account = item.account { line += " · \(VaultContainer.accountTitle(account))" }
                if item.environment != .none { line += " · \(item.environment.title)" }
                if let expires = item.metadata.expires { line += " · " + String(format: L("vault.readme.expires"), Format.fileStamp(expires)) }
                out += line + "\n"
                if !item.files.isEmpty { out += "  - \(L("vault.readme.files")): " + item.files.map { "`\($0.name)`" }.joined(separator: ", ") + "\n" }
                let variables = ([item.kind.fileEnvVar] + item.fields.map(\.envVar)).compactMap { $0 }.filter { !$0.isEmpty }
                if !variables.isEmpty { out += "  - \(L("vault.readme.variables")): " + variables.map { "`\($0)`" }.joined(separator: ", ") + "\n" }
                let fieldNames = item.fields.map(\.title).filter { !$0.isEmpty }
                if !fieldNames.isEmpty { out += "  - \(L("vault.readme.fields")): " + fieldNames.joined(separator: ", ") + "\n" }
                for entry in item.metadata.entries where !["vault.meta.keys"].contains(entry.key) {
                    out += "  - \(L(entry.key)): \(entry.key == "vault.meta.profileType" ? L("vault.profileType.\(entry.value)") : entry.value)\n"
                }
            }
            out += "\n"
        }
        return out
    }

    // MARK: Fields file

    /// Dotenv lines, one per field; the name is the field's variable (or one made from its label).
    static func dataFile(_ item: VaultItem) -> String {
        var out = "# Stack · \(item.name)\n# tipo: \(item.kind.rawValue)\n"
        if item.environment != .none { out += "# entorno: \(item.environment.rawValue)\n" }
        for field in item.fields {
            let name = (field.envVar?.isEmpty == false ? field.envVar! : variableName(field.title.isEmpty ? field.role.rawValue : field.title))
            out += "# \(field.role.rawValue)\(field.secret ? " secreto" : ""): \(field.title.replacingOccurrences(of: "\n", with: " "))\n"
            out += "\(name)=\(quoted(field.value))\n"
        }
        if !item.notes.isEmpty {
            out += "# notas:\n" + item.notes.split(separator: "\n", omittingEmptySubsequences: false).map { "#| \($0)" }.joined(separator: "\n") + "\n"
        }
        return out
    }

    static func variableName(_ label: String) -> String {
        let folded = label.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "es")).dataCapitals
        let mapped = String(folded.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "_" })
        let trimmed = mapped.split(separator: "_").joined(separator: "_")
        return trimmed.isEmpty ? "VALOR" : (trimmed.first!.isNumber ? "_" + trimmed : trimmed)
    }

    static func quoted(_ value: String) -> String {
        let single = value.replacingOccurrences(of: "\n", with: " ")
        guard single.contains(where: { " #\"'$\\".contains($0) }) else { return single }
        return "\"" + single.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "$", with: "\\$") + "\""
    }

    /// Reads a fields file back: kind, environment, fields (role, label, secret) and notes.
    static func parseDataFile(_ text: String) -> (kind: VaultItemKind?, environment: VaultEnvironment, fields: [VaultField], notes: String) {
        var kind: VaultItemKind?
        var environment = VaultEnvironment.none
        var notes: [String] = []
        var pending: (VaultField.Role, Bool, String)?
        var fields: [VaultField] = []
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("#| ") || line == "#|" { notes.append(String(line.dropFirst(3))); continue }
            if line.hasPrefix("# tipo: ") { kind = VaultItemKind(rawValue: String(line.dropFirst(8))); continue }
            if line.hasPrefix("# entorno: ") { environment = VaultEnvironment(rawValue: String(line.dropFirst(11))) ?? .none; continue }
            if line.hasPrefix("# "), let colon = line.firstIndex(of: ":") {
                let head = line[line.index(line.startIndex, offsetBy: 2)..<colon].split(separator: " ")
                if let first = head.first, let role = VaultField.Role(rawValue: String(first)) {
                    pending = (role, head.contains("secreto"), line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
                }
                continue
            }
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            guard let (key, value) = DotEnv.parse(line).first else { continue }
            if let (role, secret, label) = pending {
                let defaultTitle = role == .custom ? "" : L("vault.field.\(role.rawValue)")
                fields.append(VaultField(role: role, label: label == defaultTitle ? "" : label, value: value, secret: secret, envVar: key))
            } else {
                let upper = key.dataCapitals
                let secret = ["PASS", "SECRET", "TOKEN", "PRIVATE", "API_KEY", "APIKEY"].contains { upper.contains($0) }
                fields.append(VaultField(role: .custom, label: key, value: value, secret: secret, envVar: key))
            }
            pending = nil
        }
        return (kind, environment, fields, notes.joined(separator: "\n"))
    }
}
