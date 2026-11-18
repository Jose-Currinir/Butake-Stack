import CryptoKit
import Foundation

/// Reading a backup folder to import it: what each file is, which part of the app and which stage it
/// goes to, the fields that travel next to it, and what is left out by default (history, archives,
/// dumps, quarantine, `.env`, what nobody recognizes) or because it is already in the scan. A service
/// is one group whatever its subfolders: each subfolder is an account of it (`Candidate.account`).
extension VaultFolder {
    struct Candidate: Identifiable, Hashable {
        var id = UUID()
        var url: URL
        var relative: String
        var name: String
        var size: Int
        var kind: VaultItemKind
        var section: VaultSection?
        var dataFile: URL?
        var selected = true
        /// Already in the vault (same SHA-256 in the same app or service).
        var duplicate = false
        /// The stage given by its folder (`QA`, `PROD`), or by its `.datos.txt` when imported.
        var environment: VaultEnvironment = .none
        var sha256 = ""
        /// Passwords and values that belong to this file (`X.p12.pass`, `CREDENTIALS.txt`…).
        var companions: [VaultCompanions.Companion] = []
        /// A one-line file (`FIREBASE_APP_ID.txt`) kept as a value, without the file.
        var valueOnly = false
        /// Left unselected: history, an archive, a backup, a dump, a quarantine.
        var exclusion: VaultBackupLayout.Exclusion?
        /// The same bytes are already listed at this path: one copy is imported.
        var copyOf: String?
        /// Under a folder of push keys (a `.p8` there is an APNs key).
        var pushFolder = false
        /// The account of a service it comes from (`cloudflare/<cuenta>/…`); nil in an app and in the
        /// service's own folder.
        var account: String?

        /// A file nobody recognizes (not a key, a certificate, a profile, a note…): listed unselected
        /// under «Sin reconocer», to be ticked if it is wanted as «Otro archivo».
        var unrecognized: Bool {
            kind == .file && dataFile == nil && companions.isEmpty && !valueOnly && exclusion == nil && copyOf == nil
        }
        /// Never offered: a dump (personal data) or a quarantine (sensitive material).
        var sealed: Bool { exclusion?.isSealed == true }
    }

    /// Something the scan did not read, said in the summary by its path and why.
    struct Skipped: Hashable {
        enum Reason: String, CaseIterable, Hashable, Sendable { case link, tooLarge, tooDeep, tooMany, unreadable, notApp }
        var relative: String
        var reason: Reason
    }

    /// A `README.md` taken as notes: the app's or service's own, or one of an account of a service.
    struct Readme: Hashable {
        var url: URL
        var relative: String
        var account: String?
    }

    struct Group: Identifiable, Hashable {
        var id = UUID()
        var kind: VaultContainer.Kind
        var name: String
        var bundleId: String?
        var readmes: [Readme] = []
        var files: [Candidate] = []
        var skipped: [Skipped] = []
        var existing: UUID?
        /// Services an earlier import kept apart (`cloudflare/cuenta`): this import gathers them here.
        var legacy: [UUID] = []
        var folderName: String { VaultContainer(kind: kind, name: name, bundleId: bundleId).folderName }
        /// The app's or service's own README.
        var readme: URL? { readmes.first { $0.account == nil }?.url }
        /// Something here makes or fills an app or service: a file to import, or one that already exists.
        var bringsSomething: Bool { files.contains { $0.selected && !$0.kind.isRetired } || existing != nil || !legacy.isEmpty }
    }

    /// Where a file sits: the part and stage its folders say, why it is left out, if it is, and the
    /// account of a service it belongs to.
    struct Context {
        var section: VaultSection?
        var environment: VaultEnvironment = .none
        var exclusion: VaultBackupLayout.Exclusion?
        var push = false
        /// Inside a service every subfolder that is not a stage or a left-out folder names an account.
        var tracksAccount = false
        var account: [String] = []

        func entering(_ folder: String) -> Context {
            var next = self
            let excluded = VaultBackupLayout.excluded(folder: folder)
            if let excluded { next.exclusion = next.exclusion ?? excluded }
            if next.section == nil, let section = VaultBackupLayout.section(forFolder: folder) { next.section = section }
            let environment = VaultBackupLayout.environment(forFolder: folder)
            if let environment { next.environment = environment }
            if VaultBackupLayout.isPushFolder([folder]) { next.push = true }
            if tracksAccount, excluded == nil, environment == nil, next.account.count < 3, VaultNames.isSafeComponent(folder) {
                next.account.append(folder.trimmingCharacters(in: .whitespaces))
            }
            return next
        }
    }

    /// Everything importable under `root` (the master folder, one app, `_SERVICIOS`, one service or one
    /// account of a service). Only regular files inside `root` are taken: links, hidden system files and
    /// very large files are skipped and said in the summary.
    static func scan(_ root: URL) -> [Group] {
        let root = root.standardizedFileURL.resolvingSymlinksInPath()
        var groups: [Group] = []
        var loose: [Skipped] = []
        let name = root.lastPathComponent
        let parent = root.deletingLastPathComponent().lastPathComponent
        if name == servicesFolder {
            groups += scanServices(root, root: root)
        } else if parent == servicesFolder {
            groups.append(scanService(root, name: name, account: [], root: root))
        } else if root.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == servicesFolder {
            groups.append(scanService(root, name: parent, account: [name], root: root))
        } else if looksLikeApp(root) {
            groups.append(scanApp(root, root: root))
        } else {
            for child in subdirectories(root) {
                if child.lastPathComponent == servicesFolder { groups += scanServices(child, root: root) }
                else if looksLikeApp(child) { groups.append(scanApp(child, root: root)) }
                else { loose.append(Skipped(relative: child.lastPathComponent, reason: .notApp)) }
            }
            if groups.isEmpty { groups.append(scanApp(root, root: root)); loose = [] }
        }
        groups = groups.filter { !$0.files.isEmpty || !$0.readmes.isEmpty || !$0.skipped.isEmpty }
        // Folders at the top that are neither an app nor `_SERVICIOS` go to the summary with the first group.
        if !loose.isEmpty, !groups.isEmpty { groups[0].skipped += loose }
        return removingCopies(groups)
    }

    /// Several folders in one preview (an app and `_SERVICIOS`): each is read as `scan` reads it, and the
    /// same bytes in two of them are imported once.
    static func scan(_ roots: [URL]) -> [Group] {
        roots.count == 1 ? scan(roots[0]) : removingCopies(roots.flatMap { scan($0) })
    }

    static func looksLikeApp(_ url: URL) -> Bool {
        if VaultContainer.parseAppFolder(url.lastPathComponent).bundleId != nil { return true }
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? [])
        return names.contains { VaultBackupLayout.section(forFolder: $0) != nil }
    }

    private static func subdirectories(_ url: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles])) ?? [])
            .filter(isDirectory).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private static func isDirectory(_ url: URL) -> Bool {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        return values?.isDirectory == true && values?.isSymbolicLink != true
    }

    private static func isReadme(_ file: Candidate) -> Bool { file.name.lowercased() == "readme.md" && file.exclusion == nil }

    private static func scanApp(_ folder: URL, root: URL) -> Group {
        let parsed = VaultContainer.parseAppFolder(folder.lastPathComponent)
        var group = Group(kind: .app, name: parsed.name, bundleId: parsed.bundleId)
        var skipped: [Skipped] = []
        var files = collect(folder, root: root, depth: 0, context: Context(), skipped: &skipped)
        if let index = files.firstIndex(where: { isReadme($0) && $0.url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL }) {
            let readme = files.remove(at: index)
            group.readmes = [Readme(url: readme.url, relative: readme.relative)]
        }
        for index in files.indices where files[index].section == nil { files[index].section = files[index].kind.defaultSection }
        group.files = finish(files)
        group.skipped = skipped
        return group
    }

    private static func scanServices(_ folder: URL, root: URL) -> [Group] {
        subdirectories(folder).filter { VaultNames.isSafeComponent($0.lastPathComponent) }.map { child in
            scanService(child, name: child.lastPathComponent, account: [], root: root)
        }
    }

    /// A service folder, with all its subfolders: each one that is not a stage (`QA`, `PROD`) or a left-out
    /// folder is an account of the service, never a service of its own. The README of the service and of
    /// each account are its notes; a quarantine is listed, never read.
    private static func scanService(_ folder: URL, name: String, account: [String], root: URL) -> Group {
        var group = Group(kind: .service, name: name)
        var context = Context().entering(folder.lastPathComponent)
        context.tracksAccount = true
        context.account = account
        var skipped: [Skipped] = []
        var files = collect(folder, root: root, depth: 0, context: context, skipped: &skipped)
        let base = folder.standardizedFileURL
        var readmes: [Readme] = []
        files.removeAll { file in
            guard isReadme(file) else { return false }
            // Only the README right in the service or in an account folder (not one inside `PROD/`).
            let extra = (file.account?.split(separator: "/").map(String.init) ?? []).dropFirst(account.count)
            let expected = extra.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }.standardizedFileURL
            guard file.url.deletingLastPathComponent().standardizedFileURL.path == expected.path else { return false }
            readmes.append(Readme(url: file.url, relative: file.relative, account: file.account))
            return true
        }
        group.readmes = readmes
        group.files = finish(files)
        group.skipped = skipped
        return group
    }

    /// Fields files and companions join their files; what nobody recognizes is left unselected. Dumps and
    /// quarantines take no part: nothing beside them is read.
    private static func finish(_ files: [Candidate]) -> [Candidate] {
        let open = associate(attachDataFiles(files.filter { !$0.sealed }))
        return open.map { file in
            var file = file
            if file.unrecognized { file.selected = false }
            return file
        } + files.filter(\.sealed)
    }

    private static func collect(_ folder: URL, root: URL, depth: Int, context: Context, recurse: Bool = true, skipped: inout [Skipped]) -> [Candidate] {
        let rootPath = root.standardizedFileURL.path
        func relative(_ url: URL) -> String {
            let path = url.standardizedFileURL.path
            return path.hasPrefix(rootPath + "/") ? String(path.dropFirst(rootPath.count + 1)) : url.lastPathComponent
        }
        guard depth <= 5 else { skipped.append(Skipped(relative: relative(folder), reason: .tooDeep)); return [] }
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey]
        let entries = ((try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? [])
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        var out: [Candidate] = []
        for url in entries {
            let name = url.lastPathComponent
            if [".DS_Store", ".localized", "Icon\r"].contains(name) || name.hasPrefix("._") { continue }
            guard let values = try? url.resourceValues(forKeys: Set(keys)) else {
                skipped.append(Skipped(relative: relative(url), reason: .unreadable)); continue
            }
            let resolved = url.standardizedFileURL.resolvingSymlinksInPath().path
            guard values.isSymbolicLink != true, resolved.hasPrefix(rootPath + "/") else {
                skipped.append(Skipped(relative: relative(url), reason: .link)); continue
            }
            if values.isDirectory == true {
                // Hidden folders (.git…) are skipped; hidden files like .env are kept.
                if recurse && !name.hasPrefix(".") {
                    out += collect(url, root: root, depth: depth + 1, context: context.entering(name), skipped: &skipped)
                }
                continue
            }
            guard values.isRegularFile == true, let size = values.fileSize else { continue }
            guard size <= maximumFileSize else { skipped.append(Skipped(relative: relative(url), reason: .tooLarge)); continue }
            let exclusion = context.exclusion ?? VaultBackupLayout.excluded(file: name)
            // A dump or a quarantine is listed by its name only: not a byte of it is read.
            let sealed = exclusion?.isSealed == true
            let head = sealed ? nil : (try? FileHandle(forReadingFrom: url)).flatMap { handle in defer { try? handle.close() }; return try? handle.read(upToCount: 64_000) }
            let kind = sealed ? VaultItemKind.file : VaultInspector.detectKind(name: name, data: head)
            var candidate = Candidate(url: url, relative: relative(url), name: name, size: size, kind: kind,
                                      section: context.section ?? kind.defaultSection)
            candidate.environment = context.environment
            candidate.exclusion = exclusion
            candidate.pushFolder = context.push
            candidate.account = context.account.isEmpty ? nil : context.account.joined(separator: "/")
            candidate.selected = exclusion == nil
            out.append(candidate)
            if out.count >= maximumFiles { skipped.append(Skipped(relative: relative(folder), reason: .tooMany)); break }
        }
        return out
    }

    /// `<archivo>.datos.txt` joins the file it belongs to; one with no file becomes an item of its own.
    private static func attachDataFiles(_ files: [Candidate]) -> [Candidate] {
        var result = files.filter { !$0.name.hasSuffix(dataSuffix) }
        for data in files where data.name.hasSuffix(dataSuffix) {
            let owner = String(data.name.dropLast(dataSuffix.count))
            let folder = data.url.deletingLastPathComponent().standardizedFileURL
            if let index = result.firstIndex(where: { $0.name == owner && $0.url.deletingLastPathComponent().standardizedFileURL == folder }) {
                result[index].dataFile = data.url
            } else {
                var standalone = data
                standalone.name = owner
                standalone.dataFile = data.url
                standalone.kind = .token
                result.append(standalone)
            }
        }
        return result
    }

    /// The same bytes twice in the scan (a certificate kept in QA and in PROD, in an app and in
    /// `_SERVICIOS`): the first is imported, for both stages when the copies differ in it; the others
    /// are listed unselected, with where the first one is. Dumps and quarantines are not read.
    static func removingCopies(_ groups: [Group]) -> [Group] {
        var groups = groups
        var first: [String: (group: Int, file: Int)] = [:]
        for g in groups.indices {
            for f in groups[g].files.indices where !groups[g].files[f].valueOnly && !groups[g].files[f].sealed && groups[g].files[f].dataFile != groups[g].files[f].url {
                guard let data = try? Data(contentsOf: groups[g].files[f].url) else { continue }
                let hash = VaultCrypto.sha256(data)
                groups[g].files[f].sha256 = hash
                guard let (fg, ff) = first[hash] else {
                    if groups[g].files[f].exclusion == nil { first[hash] = (g, f) }
                    continue
                }
                var copy = groups[g].files[f]
                copy.copyOf = groups[fg].files[ff].relative
                copy.selected = false
                if copy.exclusion == nil {
                    if copy.environment != groups[fg].files[ff].environment { groups[fg].files[ff].environment = .none }
                    if groups[fg].files[ff].companions.isEmpty { groups[fg].files[ff].companions = copy.companions }
                }
                groups[g].files[f] = copy
            }
        }
        return groups
    }
}
