import AppKit
import CryptoKit
import Foundation
import LocalAuthentication

/// What the user takes out of an unlocked vault: a secret value shown or copied, a file saved.
extension VaultSession {
    // MARK: Reveal, copy, files

    func reveal(_ field: VaultField, of item: VaultItem) async {
        guard await confirmPresence(L("vault.auth.reveal"), fresh: false) else { return }
        revealed[field.id] = field.value
        disk.append(VaultAccessEntry(action: .reveal, target: item.id))
        let id = field.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(30))
            self?.revealed[id] = nil
        }
    }

    func hide(_ field: VaultField) { revealed[field.id] = nil }

    func copy(_ field: VaultField, of item: VaultItem) async {
        if field.secret { guard await confirmPresence(L("vault.auth.copy"), fresh: false) else { return } }
        touch()
        Self.copyConcealed(field.value)
        disk.append(VaultAccessEntry(action: .copy, target: item.id))
        notice = L("vault.copied")
    }

    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")
    @ObservationIgnored private static var copiedChange: Int?

    /// Marked as concealed (clipboard managers skip it) and cleared after 30 s if it is still there.
    static func copyConcealed(_ value: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.declareTypes([.string, concealedType], owner: nil)
        pasteboard.setString(value, forType: .string)
        pasteboard.setString("", forType: concealedType)
        let count = pasteboard.changeCount
        copiedChange = count
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(30))
            if NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        }
    }

    func clearClipboardIfOurs() {
        if let count = Self.copiedChange, NSPasteboard.general.changeCount == count { NSPasteboard.general.clearContents() }
        Self.copiedChange = nil
    }

    func fileData(_ file: VaultFile) throws -> Data {
        let data = try disk.readBlob(file.id, key: try requireKey())
        guard VaultCrypto.sha256(data) == file.sha256 else { throw VaultError.corrupt }
        return data
    }

    /// One file out of the vault, to a place the user picks.
    func saveFile(_ file: VaultFile, of item: VaultItem) async {
        guard await confirmPresence(L("vault.auth.saveFile"), fresh: true) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.name
        panel.message = L("vault.saveFileMessage")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try fileData(file)
            FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            try data.write(to: url)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            disk.append(VaultAccessEntry(action: .saveFile, target: item.id))
            notice = L("vault.fileSaved")
        } catch { message = L((error as? VaultError)?.messageKey ?? VaultError.io.messageKey) }
    }
}
