import Foundation

/// Joins the files of a scanned folder that only carry values to the file they belong to, and gives
/// the kinds a backup's folders make clear (a `.p8` under APNs, a certificate's `.key`).
///
/// Rules, always within one folder:
/// - `X.p12.pass|.clave|.password` → the password of `X.p12` (or of `X.*`): certain. With no file of that
///   name and a single certificate or keystore in the folder, only proposed.
/// - `CREDENTIALS.txt`, `keystore.properties` → store password, alias and key password of the folder's
///   only keystore: certain. With several, the one it names, or a proposal for the first.
/// - `fastlane.env` → Key ID and Issuer ID of the folder's only `.p8` (or of `AuthKey_<Key ID>.p8`).
/// - `NOMBRE_EN_MAYUSCULAS.txt` with one line (`FIREBASE_APP_ID.txt`) → a value of its own.
/// A proposal is taken only when the user accepts it in the preview; a companion with nothing to read
/// stays a file of its own.
extension VaultFolder {
    static func associate(_ input: [Candidate]) -> [Candidate] {
        var files = input
        let snapshot = files
        for index in files.indices { refineKind(&files[index], among: snapshot) }
        var consumed = Set<Int>()
        let folders = Dictionary(grouping: files.indices) { files[$0].url.deletingLastPathComponent().standardizedFileURL.path }
        for positions in folders.values {
            for position in positions {
                let file = files[position]
                guard file.dataFile == nil, !file.valueOnly, let source = VaultCompanions.source(of: file.name), source != .value,
                      let (target, certain) = target(of: file, source: source, among: positions.filter { $0 != position && !files[$0].valueOnly }, files: files) else { continue }
                var companion = VaultCompanions.Companion(url: file.url, name: file.name, source: source, roles: [], certain: certain, accepted: false)
                if source == .fastlane, files[target].kind == .apnsKey { files[target].kind = .appStoreKey }
                companion.roles = VaultCompanions.roles(companion, for: files[target].kind)
                guard !companion.roles.isEmpty else { continue }
                files[target].companions.append(companion)
                consumed.insert(position)
            }
        }
        return files.indices.filter { !consumed.contains($0) }.map { files[$0] }
    }

    /// Kinds only the backup's layout tells: one-line value files, APNs keys and certificates' keys.
    private static func refineKind(_ file: inout Candidate, among files: [Candidate]) {
        if file.dataFile == nil, VaultCompanions.source(of: file.name) == .value,
           let text = VaultCompanions.text(file.url), VaultCompanions.value(text) != nil {
            file.companions = [VaultCompanions.Companion(url: file.url, name: file.name, source: .value, roles: [.token], certain: true, accepted: true)]
            file.valueOnly = true
            file.kind = .token
            file.name = (file.name as NSString).deletingPathExtension
            return
        }
        if file.kind == .appStoreKey && file.pushFolder { file.kind = .apnsKey }
        let ext = (file.name as NSString).pathExtension.lowercased()
        if file.kind == .sshKey, ["pem", "key"].contains(ext) {
            let stem = (file.name as NSString).deletingPathExtension
            let folder = file.url.deletingLastPathComponent().standardizedFileURL
            let paired = files.contains { other in
                other.url.deletingLastPathComponent().standardizedFileURL == folder
                    && (other.name as NSString).deletingPathExtension == stem
                    && ["cer", "crt", "p12", "pfx", "csr"].contains((other.name as NSString).pathExtension.lowercased())
            }
            if paired || file.section == .ios { file.kind = .certificateKey; file.section = .ios }
        }
    }

    /// The file a companion belongs to, and whether there is no doubt.
    private static func target(of companion: Candidate, source: VaultCompanions.Source, among positions: [Int], files: [Candidate]) -> (Int, Bool)? {
        func of(_ kinds: Set<VaultItemKind>) -> [Int] { positions.filter { kinds.contains(files[$0].kind) } }
        switch source {
        case .password:
            let stem = VaultCompanions.passwordTarget(companion.name) ?? ""
            let signing = of([.iosCertificate, .androidKeystore, .certificateKey])
            if let exact = signing.first(where: { files[$0].name == stem }) ?? signing.first(where: { (files[$0].name as NSString).deletingPathExtension == stem }) {
                return (exact, true)
            }
            return signing.count == 1 ? (signing[0], false) : nil
        case .credentials:
            let keystores = of([.androidKeystore])
            if keystores.count == 1 { return (keystores[0], true) }
            if keystores.count > 1 {
                let text = VaultCompanions.text(companion.url) ?? ""
                if let named = keystores.first(where: { text.contains(files[$0].name) }) { return (named, true) }
                return (keystores[0], false)
            }
            let certificates = of([.iosCertificate])
            return certificates.count == 1 ? (certificates[0], false) : nil
        case .fastlane:
            let keys = of([.appStoreKey, .apnsKey])
            if keys.count == 1 { return (keys[0], true) }
            let keyId = VaultCompanions.text(companion.url).flatMap { VaultCompanions.fastlane($0)[.keyId] }
            if let keyId, let named = keys.first(where: { VaultInspector.appStoreKeyId(files[$0].name) == keyId }) { return (named, true) }
            return keys.first.map { ($0, false) }
        case .value:
            return nil
        }
    }
}
