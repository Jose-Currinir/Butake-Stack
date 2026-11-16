import AppKit
import SwiftUI

/// What the engine found on this Mac for a clone over SSH (`gitSshAccess`): Git's own `ssh` can
/// not ask anything, so the sheet shows what is missing and how to fix it without leaving Stack.
struct GitSSHAccess: Decodable, Equatable, Sendable {
    var ssh = false
    var host = ""
    var port = 22
    /// The server is among the known hosts of this Mac.
    var hostKnown = false
    /// There is a key to offer: one in the agent or a default one in `~/.ssh`.
    var identities = false

    /// The clone cannot work yet: the server would be refused before anything is asked.
    var blocked: Bool { ssh && !hostKnown }
}

/// The fingerprints a server presents now (`gitSshFingerprints`), to accept or not.
struct GitSSHFingerprints: Decodable, Equatable, Sendable, Identifiable {
    var host: String
    var port: Int
    var fingerprints: [String]
    /// Every one is among those its provider publishes (GitHub, Bitbucket Cloud).
    var official: Bool
    var id: String { "\(host):\(port)" }

    var message: String {
        String(format: L(official ? "git.access.trust.official" : "git.access.trust.unverified"), fingerprints.joined(separator: "\n"))
    }
}

extension GitHosting {
    func sshAccess(url: String, store: StackStore) async -> GitSSHAccess? {
        try? await store.call(["method": "gitSshAccess", "url": url])
    }

    func sshFingerprints(url: String, store: StackStore) async throws -> GitSSHFingerprints {
        try await store.call(["method": "gitSshFingerprints", "url": url])
    }

    /// Adds the server to the known hosts when it still presents the fingerprints the user saw.
    func sshTrust(url: String, seen: GitSSHFingerprints, store: StackStore) async throws {
        let _: Bool = try await store.call(["method": "gitSshTrust", "url": url, "fingerprints": seen.fingerprints, "confirmed": true])
    }
}

extension GitHostingProvider {
    /// Where the user registers a public SSH key, on the provider's own site.
    var sshKeysPage: URL {
        switch self {
        case .github: URL(string: "https://github.com/settings/keys")!
        case .bitbucket: URL(string: "https://bitbucket.org/account/settings/ssh-keys/")!
        }
    }
}

/// Inside «Clonar…»: what an SSH address still needs on this Mac, each with its way out — trust
/// the server after seeing its fingerprints, use one of Stack's keys (or create one in Ajustes ›
/// Claves SSH) and register its public half on the provider. `refused` is the code of the last
/// clone that failed for access, when there was one.
struct GitCloneAccessNotice: View {
    let url: String
    let access: GitSSHAccess?
    let refused: String?
    /// Reads the access again (after trusting, loading a key or coming back from Ajustes).
    let refresh: () async -> Void
    /// Switches the clone to SSH; nil when the address is typed by hand.
    var useSSH: (() -> Void)?
    /// How many notices show, for the sheet to make room.
    @Binding var shown: Int
    var hosting = GitHosting.shared
    @Bindable var keyring = SSHKeyring.shared
    @State private var trusting: GitSSHFingerprints?
    @State private var working = false
    @State private var problem: String?
    /// The key of Stack offered to Git in this sheet: its public half is the one to register.
    @State private var offered: SSHKey?

    private var provider: GitHostingProvider? { GitHostedRepository(remote: url, endpoints: hosting.endpoints)?.provider }
    private var where_: String { provider?.title ?? access?.host ?? "" }
    private var needsPublic: Bool { refused == "clone_ssh_denied" || offered != nil }
    private var count: Int {
        guard let access, access.ssh else { return refused == "clone_auth" ? 1 : 0 }
        return (access.hostKnown ? 0 : 1) + (!access.identities || needsPublic ? 1 : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let access, access.ssh {
                if !access.hostKnown { hostNotice(access) }
                if !access.identities { keyNotice } else if needsPublic { publicNotice }
            } else if refused == "clone_auth" {
                Notice(.warning, L("git.access.https.title"), detail: L("git.access.https.detail")) {
                    if let useSSH {
                        Button(action: useSSH) { Label(L("git.access.https.useSSH"), systemImage: Symbols.key) }
                            .buttonStyle(.bordered).accessibilityIdentifier("git.access.https.useSSH")
                    }
                }
            }
            if let problem {
                Label(problem, systemImage: Symbols.warning).font(.uiCaption).foregroundStyle(Brand.danger)
                    .accessibilityIdentifier("git.access.problem")
            }
        }
        .task { await keyring.load() }
        .onChange(of: count, initial: true) { shown = count }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // Back from Ajustes › Claves SSH (or from the provider's page): what changed shows.
            Task { await keyring.load(); await refresh() }
        }
        .confirmationDialog(String(format: L("git.access.trust.title"), trusting?.host ?? ""), isPresented: Binding(get: { trusting != nil }, set: { if !$0 { trusting = nil } }),
                            titleVisibility: .visible, presenting: trusting) { seen in
            Button(L("git.access.trust.action")) { Task { await trust(seen) } }.accessibilityIdentifier("git.access.trust.confirm")
            Button(L("common.cancel"), role: .cancel) {}.accessibilityIdentifier("git.access.trust.cancel")
        } message: { seen in
            Text(seen.message)
        }
    }

    private func hostNotice(_ access: GitSSHAccess) -> some View {
        Notice(.warning, String(format: L("git.access.host.title"), access.host), detail: L("git.access.host.detail")) {
            Button { Task { await readFingerprints() } } label: { Label(L("git.access.host.review"), systemImage: Symbols.checkIdentity) }
                .buttonStyle(.borderedProminent).disabled(working).accessibilityIdentifier("git.access.host.review")
        }
    }

    @ViewBuilder private var keyNotice: some View {
        if keyring.sshKeys.isEmpty {
            Notice(.warning, L("git.access.key.title"), detail: L("git.access.key.detailNone")) {
                Button { SettingsRouter.shared.open(.keys) } label: { Label(L("git.access.key.create"), systemImage: Symbols.settings) }
                    .buttonStyle(.bordered).accessibilityIdentifier("git.access.key.create")
            }
        } else {
            Notice(.warning, L("git.access.key.title"), detail: L("git.access.key.detailStack")) {
                Menu {
                    ForEach(keyring.sshKeys) { key in
                        Button(key.name) { Task { await offer(key) } }.accessibilityIdentifier("git.access.key.use.\(key.id)")
                    }
                    Divider()
                    Button(L("git.access.key.create")) { SettingsRouter.shared.open(.keys) }.accessibilityIdentifier("git.access.key.settings")
                } label: { Label(L("git.access.key.use"), systemImage: Symbols.key) }
                    .fixedSize().disabled(working).accessibilityIdentifier("git.access.key.use")
            }
        }
    }

    private var publicNotice: some View {
        Notice(refused == "clone_ssh_denied" ? .warning : .info, String(format: L("git.access.public.title"), where_), detail: L("git.access.public.detail")) {
            if let offered {
                Button { Task { await keyring.copyPublicKey(offered.id) } } label: { Label(L("git.access.public.copy"), systemImage: Symbols.copy) }
                    .buttonStyle(.bordered).accessibilityIdentifier("git.access.public.copy")
            } else if !keyring.sshKeys.isEmpty {
                Menu {
                    ForEach(keyring.sshKeys) { key in
                        Button(key.name) { Task { await keyring.copyPublicKey(key.id) } }.accessibilityIdentifier("git.access.public.copy.\(key.id)")
                    }
                } label: { Label(L("git.access.public.copy"), systemImage: Symbols.copy) }
                    .fixedSize().accessibilityIdentifier("git.access.public.copy")
            }
            if let provider {
                Button { NSWorkspace.shared.open(provider.sshKeysPage) } label: { Label(String(format: L("git.access.public.open"), provider.title), systemImage: Symbols.openInBrowser) }
                    .buttonStyle(.bordered).accessibilityIdentifier("git.access.public.open")
            }
        }
    }

    private func readFingerprints() async {
        working = true
        defer { working = false }
        problem = nil
        do { trusting = try await hosting.sshFingerprints(url: url, store: StackStore.shared) } catch { problem = Self.text(error) }
    }

    private func trust(_ seen: GitSSHFingerprints) async {
        working = true
        defer { working = false }
        problem = nil
        do {
            try await hosting.sshTrust(url: url, seen: seen, store: StackStore.shared)
            StackStore.shared.notify(String(format: L("git.access.trusted"), seen.host))
        } catch { problem = Self.text(error) }
        await refresh()
    }

    /// One of Stack's keys into the agent, where Git's `ssh` finds it.
    private func offer(_ key: SSHKey) async {
        working = true
        defer { working = false }
        problem = nil
        if await keyring.offerToAgent(key) {
            offered = key
            StackStore.shared.notify(String(format: L("git.access.key.loaded"), key.name))
        }
        await refresh()
    }

    private static func text(_ error: Error) -> String {
        let failure = GitFailure(error)
        return failure.detail.isEmpty ? failure.title : "\(failure.title): \(failure.detail)"
    }
}
