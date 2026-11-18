#if DEBUG
import AppKit
import CryptoKit
import LocalAuthentication
import Security
import SwiftUI

/// QA of the vault without touching the user's data or driving the mouse (debug builds, with
/// BUTAKE_QA_WINDOW and a separate BUTAKE_STACK_HOME):
///
///     BUTAKE_QA_VAULT=<carpeta>|1     open "Bóveda" unlocked (QA Keychain service, no prompts);
///                                     a folder is imported the first time, like the master backup
///     BUTAKE_QA_VAULT_SELECT=<nombre> app or service to show ("expiring" for Por vencer)
///     BUTAKE_QA_VAULT_SEARCH=<texto>  search
///     BUTAKE_QA_VAULT_SHEET=log|export|download|newApp|item|folder|locked|absent
///                                     (log: Registros filtered on the vault's access log;
///                                     absent: the vault not created yet, in a store without one)
///     BUTAKE_QA_VAULT_REVEAL=1        reveal the first secret field shown
///     BUTAKE_QA_VAULT_INSPECT=1       the first item with fields open in the detail
///     BUTAKE_QA_VAULT_RETIRED=1|env   add a .env and an SSH key (kinds the vault no longer creates,
///                                     still shown) to the selected app, the key (or the .env) open
///     BUTAKE_QA_VAULT_PROJECT=<id>|-  link the selected app to that project (its page lists the app's
///                                     items), or unlink it
///     BUTAKE_QA_VAULT_SSHKEY=<ruta>   with _RETIRED, the SSH key item holds this (throwaway) private key
///     BUTAKE_QA_VAULT_LOCK=1          lock the vault once set up (a project's page with the vault locked)
///     BUTAKE_QA_VAULT_MOVE=confirm|done  the move sheet with its confirmation open, or moved (values in
///                                     memory, never the Keychain; the key into the temporary store)
///     BUTAKE_QA_VAULT_BACKUP=<carpeta> a keys backup by platform and stage imported instead of the
///                                     folder of BUTAKE_QA_VAULT (and shown by _SHEET=folder)
///     BUTAKE_QA_VAULT_SHEET=signing   «Firma» of the selected app (BUTAKE_QA_VAULT_STAGE=test|prod)
///     BUTAKE_QA_VAULT_MEMORY=1        the vault's key in memory instead of the QA Keychain service
///     BUTAKE_QA_VAULT_LINK=<enlace>   open that butakestack://vault/import link once set up (with
///                                     _SHEET=link), or on the locked vault (with _SHEET=locked)
///     BUTAKE_QA_VAULT_LEGACY=1        before importing, what an earlier importer left (P-40): services
///                                     named by path (`cloudflare/cuenta`) and empty ones
///     BUTAKE_QA_VAULT_SHEET=lastImport «Última importación» (the summary kept by the last import)
///     BUTAKE_QA_VAULT_SUMMARY_OPEN=<categorías> the import summary with those categories unfolded
///     BUTAKE_QA_SNAPSHOT=<ruta.png>   save the window (and an open sheet as <ruta>-sheet.png), then quit
@MainActor enum VaultQA {
    static func start() async {
        let environment = ProcessInfo.processInfo.environment
        guard environment["BUTAKE_STACK_HOME"] != nil else { return }
        let vault = VaultSession.shared
        try? await Task.sleep(for: .seconds(1.2))
        // A project's page (BUTAKE_QA_ROUTE) stays where it is; the vault is set up behind it.
        if environment["BUTAKE_QA_ROUTE"] == nil { StackStore.shared.route = .tool("vault") }
        vault.refreshState()
        let link = environment["BUTAKE_QA_VAULT_LINK"].flatMap(URL.init(string:))
        if ["locked", "absent"].contains(environment["BUTAKE_QA_VAULT_SHEET"]) {
            if let link { StackStore.shared.handle(link) }
            await snapshot(); return
        }
        if vault.state == .absent { await vault.create() } else { await vault.unlock() }
        let folder = environment["BUTAKE_QA_VAULT_BACKUP"] ?? environment["BUTAKE_QA_VAULT"]
        // The preview of a backup (_SHEET=folder with _BACKUP) shows it before anything is imported.
        let previewOnly = environment["BUTAKE_QA_VAULT_SHEET"] == "folder" && environment["BUTAKE_QA_VAULT_BACKUP"] != nil
        if environment["BUTAKE_QA_VAULT_LEGACY"] != nil, vault.index.containers.isEmpty { await seedLegacy(vault) }
        if let path = folder, path != "1", vault.index.containers.isEmpty, !previewOnly {
            let url = URL(fileURLWithPath: path)
            await vault.importFolder(vault.markDuplicates(VaultFolder.scan(url)), folders: [url.lastPathComponent])
        }
        let select = environment["BUTAKE_QA_VAULT_SELECT"]
        if select == "expiring" { vault.selection = .expiring }
        else if let container = vault.index.containers.first(where: { $0.name == select || $0.folderName == select })
                    ?? vault.index.containers.filter({ $0.kind == .app }).sorted(by: { $0.name < $1.name }).first {
            vault.selection = .container(container.id)
        }
        if let search = environment["BUTAKE_QA_VAULT_SEARCH"] { vault.search = search }
        if environment["BUTAKE_QA_VAULT_RETIRED"] != nil, case .container(let id)? = vault.selection {
            _ = try? await vault.store(VaultItem(container: id, section: .server, kind: .envFile, name: ".env.production", environment: .prod),
                                       files: [(".env.production", Data("APP_ENV=production\nAPP_KEY=no-es-real\nSTRIPE_SECRET=no-es-real\nMAIL_MAILER=ses\n".utf8))])
            let key = environment["BUTAKE_QA_VAULT_SSHKEY"].flatMap { FileManager.default.contents(atPath: $0) }
            _ = try? await vault.store(VaultItem(container: id, section: .server, kind: .sshKey, name: "deploy_ed25519",
                                                 fields: VaultItemKind.sshKey.templateFields), files: key.map { [("deploy_ed25519", $0)] } ?? [])
            let shown: VaultItemKind = environment["BUTAKE_QA_VAULT_RETIRED"] == "env" ? .envFile : .sshKey
            vault.inspected = vault.index.items(in: id).first { $0.kind == shown }?.id
        }
        if environment["BUTAKE_QA_VAULT_INSPECT"] != nil, case .container(let id)? = vault.selection {
            vault.inspected = vault.index.items(in: id).first { !$0.fields.isEmpty }?.id ?? vault.index.items(in: id).first?.id
        }
        if environment["BUTAKE_QA_VAULT_REVEAL"] != nil, case .container(let id)? = vault.selection,
           let item = vault.index.items(in: id).first(where: { $0.fields.contains { $0.secret && !$0.value.isEmpty } }),
           let field = item.fields.first(where: { $0.secret && !$0.value.isEmpty }) {
            await vault.reveal(field, of: item)
        }
        if let project = environment["BUTAKE_QA_VAULT_PROJECT"], case .container(let id)? = vault.selection, var container = vault.index.container(id) {
            container.project = project == "-" ? nil : project
            try? vault.updateContainer(container)
        }
        try? await Task.sleep(for: .seconds(0.8))
        let selected = vault.selection.flatMap { selection -> UUID? in if case .container(let id) = selection { id } else { nil } }
        func item(_ kind: VaultItemKind) -> UUID? { selected.flatMap { id in vault.index.items(in: id).last { $0.kind == kind }?.id } }
        switch environment["BUTAKE_QA_VAULT_SHEET"] {
        case "editApp": if let selected { vault.sheet = .editContainer(selected) }
        case "moveEnv": if let id = item(.envFile) { vault.inspected = id; vault.sheet = .moveToEnvironments(id) }
        case "moveKey": if let id = item(.sshKey) { vault.inspected = id; vault.sheet = .moveToKeys(id) }
        case "log": StackStore.shared.showLogs(LogsBrowser.vaultSource)
        case "export": vault.sheet = .exportArchive(nil)
        case "download": vault.sheet = .download(nil)
        case "newApp": vault.sheet = .newContainer(.app)
        case "item":
            if case .container(let id)? = vault.selection, let item = vault.index.items(in: id).first(where: { !$0.fields.isEmpty }) { vault.sheet = .item(item) }
        case "folder":
            if let path = folder, path != "1" { vault.previewImport([URL(fileURLWithPath: path)]) }
        case "link": if let link { StackStore.shared.handle(link) }
        case "lastImport": vault.sheet = .lastImport
        case "signing":
            if let stage = environment["BUTAKE_QA_VAULT_STAGE"].flatMap(VaultEnvironment.init(rawValue:)) { vault.signingEnvironment = stage }
            if let selected { vault.openSigning(selected) }
        default: break
        }
        if environment["BUTAKE_QA_VAULT_LOCK"] != nil { vault.lock() }
        await snapshot()
    }

    /// The categories of the import summary shown unfolded (BUTAKE_QA_VAULT_SUMMARY_OPEN).
    static var summaryOpen: Set<String> {
        Set((ProcessInfo.processInfo.environment["BUTAKE_QA_VAULT_SUMMARY_OPEN"] ?? "").split(separator: ",").map(String.init))
    }

    /// What the importer before P-40 left: an account as a service named by its path, with its item, and
    /// services that only had a README (no items).
    private static func seedLegacy(_ vault: VaultSession) async {
        _ = try? vault.addContainer(kind: .service, name: "aws", bundleId: nil, notes: "# aws")
        _ = try? vault.addContainer(kind: .service, name: "cloudflare", bundleId: nil, notes: "# cloudflare")
        _ = try? vault.addContainer(kind: .service, name: "github/_CUARENTENA-NOMBRE-SENSIBLE-2026-09-09", bundleId: nil, notes: "# Cuarentena")
        if let account = try? vault.addContainer(kind: .service, name: "cloudflare/cuenta@ejemplo.cl", bundleId: nil) {
            _ = try? await vault.store(VaultItem(container: account, kind: .note, name: "api-token.txt"), files: [("api-token.txt", Data("token de prueba, no es real\n".utf8))])
        }
    }

    // MARK: Moving out of the vault

    /// A QA window keeps the values it moves in memory: the Keychain is never written.
    static var envSecrets: EnvSecretStore? {
        let environment = ProcessInfo.processInfo.environment
        return StackStore.qaWindow && environment["BUTAKE_STACK_HOME"] != nil && environment["BUTAKE_QA_VAULT"] != nil ? memory : nil
    }
    private static let memory = EnvSecrets(items: MemoryKeychainItems())

    /// The move sheet with its confirmation open (`confirm`) or already moved (`done`).
    static func moveStage(confirming: Binding<Bool>, run: () async -> Void) async {
        guard StackStore.qaWindow else { return }
        switch ProcessInfo.processInfo.environment["BUTAKE_QA_VAULT_MOVE"] {
        case "confirm": try? await Task.sleep(for: .seconds(2.5)); confirming.wrappedValue = true
        case "done": try? await Task.sleep(for: .seconds(1)); await run()
        default: break
        }
    }

    private static func snapshot() async {
        // A sweep of sizes (BUTAKE_QA_SIZES) is taken by QAHooks, with its layout report.
        guard let path = ProcessInfo.processInfo.environment["BUTAKE_QA_SNAPSHOT"], ProcessInfo.processInfo.environment["BUTAKE_QA_SIZES"] == nil else { return }
        try? await Task.sleep(for: .seconds(2.5))
        let windows = NSApp.windows.filter { $0.isVisible && $0.contentView != nil && $0.frame.width > 300 }
        guard let main = windows.first(where: { $0.sheetParent == nil && $0.identifier?.rawValue.contains("main") == true }) ?? windows.first(where: { $0.sheetParent == nil }) else { return }
        write(main, to: path)
        if let sheet = main.attachedSheet { write(sheet, to: path.replacingOccurrences(of: ".png", with: "-sheet.png")) }
        try? await Task.sleep(for: .seconds(0.3))
        NSApp.terminate(nil)
    }

    private static func write(_ window: NSWindow, to path: String) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
    }
}

/// The vault's key in memory, for a QA window with a temporary HOME: it never reaches the Keychain and
/// is gone when the window closes.
final class MemoryVaultKeyStore: VaultKeyStore {
    private var keys: [String: SymmetricKey] = [:]
    func create(keyId: String) throws -> SymmetricKey { let key = VaultCrypto.newKey(); keys[keyId] = key; return key }
    func load(keyId: String, context: LAContext?) throws -> SymmetricKey {
        guard let key = keys[keyId] else { throw VaultError.missingKey }
        return key
    }
    func delete(keyId: String) { keys[keyId] = nil }
}

/// Keychain items in memory: what a QA window moves never reaches the Keychain, and tests can play
/// the user denying access (`denied`) or macOS refusing to delete another build's item (`undeletable`).
final class MemoryKeychainItems: KeychainItems, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: (data: Data, attributes: Data?)] = [:]
    private var deniedAccounts: Set<String> = []
    private var undeletableAccounts: Set<String> = []
    private var readLog: [String] = []

    /// Accounts whose value a read is refused for, as when the user denies access.
    var denied: Set<String> {
        get { lock.withLock { deniedAccounts } }
        set { lock.withLock { deniedAccounts = newValue } }
    }
    /// Accounts macOS would not let this build delete.
    var undeletable: Set<String> {
        get { lock.withLock { undeletableAccounts } }
        set { lock.withLock { undeletableAccounts = newValue } }
    }
    /// Every value read, in order: each one is an access macOS may ask the user for.
    var reads: [String] { lock.withLock { readLog } }
    var accounts: Set<String> { lock.withLock { Set(items.keys) } }

    func read(_ account: String) -> KeychainRead {
        lock.withLock {
            readLog.append(account)
            if deniedAccounts.contains(account) { return .failed(errSecAuthFailed) }
            return items[account].map { .found($0.data) } ?? .missing
        }
    }
    func write(_ data: Data, account: String, label: String, attributes: Data?) -> Bool {
        lock.withLock { items[account] = (data, attributes); return true }
    }
    func list(prefix: String) -> [KeychainEntry] {
        lock.withLock { items.filter { $0.key.hasPrefix(prefix) }.map { KeychainEntry(account: $0.key, attributes: $0.value.attributes) } }
    }
    @discardableResult func remove(_ account: String, quietly: Bool) -> Bool {
        lock.withLock {
            if undeletableAccounts.contains(account) { return false }
            items[account] = nil
            return true
        }
    }
}
#endif
