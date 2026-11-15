import Foundation

/// `butakestack://vault/import?path=<carpeta>[&path=<otra>]` (P-38): a link leaves the import of one or
/// more backup folders ready, and the user still reviews and confirms it in «Importar carpeta…». The link
/// never imports, never unlocks and reads nothing while the vault is locked.
enum VaultImportLink {
    static let maximumFolders = 8

    /// Why a link's folder is turned down; the whole link is, so nothing is half proposed.
    enum Reason: String, CaseIterable { case none, tooMany, notAbsolute, parent, missing, notFolder }
    struct Problem: Error, Equatable {
        var path: String
        var reason: Reason
    }

    /// The folders of the link's `path` items: absolute, without `..`, existing and folders. Repeated
    /// folders are kept once. Any problem turns the whole link down.
    static func folders(_ items: [URLQueryItem]?) -> Result<[URL], Problem> {
        let paths = (items ?? []).filter { $0.name == "path" }.map { $0.value ?? "" }
        guard !paths.isEmpty else { return .failure(Problem(path: "", reason: .none)) }
        guard paths.count <= maximumFolders else { return .failure(Problem(path: "", reason: .tooMany)) }
        var folders: [URL] = []
        for path in paths {
            guard path.hasPrefix("/"), !path.contains("\0") else { return .failure(Problem(path: path, reason: .notAbsolute)) }
            let standard = URL(fileURLWithPath: path).standardizedFileURL
            // A link that climbs (`/a/../b`) is suspicious even if it lands somewhere valid.
            guard !path.split(separator: "/").contains(".."), !standard.pathComponents.contains("..") else {
                return .failure(Problem(path: path, reason: .parent))
            }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: standard.path, isDirectory: &isDirectory) else {
                return .failure(Problem(path: path, reason: .missing))
            }
            guard isDirectory.boolValue else { return .failure(Problem(path: path, reason: .notFolder)) }
            if !folders.contains(standard) { folders.append(standard) }
        }
        return .success(folders)
    }

    static func message(_ problem: Problem) -> String {
        let reason = L("vault.link.reason.\(problem.reason.rawValue)")
        return problem.path.isEmpty ? reason : String(format: L("vault.link.rejected"), problem.path, reason)
    }
}

extension VaultSession {
    /// The preview of «Importar carpeta…» for these folders; `linked` says a link proposed them.
    func previewImport(_ folders: [URL], linked: Bool = false) {
        guard isUnlocked else { return }
        let groups = markDuplicates(VaultFolder.scan(folders))
        if groups.isEmpty { message = L("vault.folderEmpty"); return }
        importFolders = folders.map(\.lastPathComponent)
        sheet = .importFolder(groups, linked: linked ? folders.map(\.path) : [])
    }

    /// A link's folders: shown in the preview now if the vault is open, otherwise kept (paths only,
    /// nothing read) until the user unlocks it. A link turned down says why and proposes nothing.
    func propose(_ items: [URLQueryItem]?) {
        switch VaultImportLink.folders(items) {
        case .failure(let problem):
            proposedFolders = []
            message = VaultImportLink.message(problem)
        case .success(let folders):
            // Never over a sheet the user is working in.
            guard sheet == nil else { message = L("vault.link.busy"); return }
            proposedFolders = folders
            if isUnlocked { previewProposed() }
        }
    }

    /// The preview of a link's folders is open in the vault: unlocking from another page must say so,
    /// because the sheet only shows on the vault's own page.
    var linkedPreviewWaiting: Bool {
        if case .importFolder(_, let linked) = sheet { !linked.isEmpty } else { false }
    }

    func previewProposed() {
        guard isUnlocked else { return }
        let folders = proposedFolders
        proposedFolders = []
        previewImport(folders, linked: true)
    }
}
