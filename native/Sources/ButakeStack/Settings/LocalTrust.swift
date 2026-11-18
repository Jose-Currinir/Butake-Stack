import AppKit
import SwiftUI

/// What macOS knows about the stack: resolver files for the local TLDs and the local CA's trust.
struct LocalTrust: Decodable, Sendable {
    struct Resolver: Decodable, Sendable, Hashable { let tld: String; let path: String; let state: String; let port: Int }
    struct Authority: Decodable, Sendable { let exists: Bool; let trusted: Bool; let fingerprint: String?; let path: String }
    let resolvers: [Resolver]
    let authority: Authority
    /// Isolated store (QA): changes are simulated inside it.
    let simulated: Bool
    var resolversReady: Bool { resolvers.allSatisfy { $0.state == "ok" } }
    /// Nothing to do: the CA only exists once Caddy served a site over HTTPS.
    var ready: Bool { resolversReady && (!authority.exists || authority.trusted) }
}

extension LocalTrust {
    static func resolverAction(_ trust: LocalTrust?) -> String {
        trust?.resolvers.contains { $0.state == "different" } == true ? L("trust.resolver.repair") : L("trust.resolver.action")
    }
    static func resolverDetail(_ trust: LocalTrust?) -> String {
        guard let trust else { return L("trust.checking") }
        if trust.resolversReady { return String(format: L("trust.resolver.ok"), trust.resolvers.map { "/etc/resolver/\($0.tld)" }.joined(separator: ", ")) }
        if trust.resolvers.contains(where: { $0.state == "different" }) { return L("trust.resolver.different") }
        return L("trust.resolver.missing")
    }
    static func caDetail(_ trust: LocalTrust?) -> String {
        guard let trust else { return L("trust.checking") }
        if !trust.authority.exists { return L("trust.ca.pending") }
        return trust.authority.trusted ? L("trust.ca.ok") : L("trust.ca.missing")
    }
}

extension View {
    /// The two confirmations asked before macOS shows its own authorization dialog.
    func trustConfirmations(store: StackStore, resolver: Binding<Bool>, ca: Binding<Bool>) -> some View {
        let trust = store.localTrust
        return confirmationDialog(L("trust.resolver.confirm"), isPresented: resolver) {
            Button(LocalTrust.resolverAction(trust)) { Task { await store.installResolver() } }.accessibilityIdentifier("trust.resolver.confirm")
        } message: { Text(String(format: L("trust.resolver.confirmDetail"), (trust?.resolvers.map { "/etc/resolver/\($0.tld)" } ?? []).joined(separator: ", "), trust?.resolvers.first?.port ?? 53)) }
        .confirmationDialog(L("trust.ca.confirm"), isPresented: ca) {
            Button(L("trust.ca.action")) { Task { await store.trustLocalCa() } }.accessibilityIdentifier("trust.ca.confirm")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(String(format: L("trust.ca.confirmDetail"), trust?.authority.fingerprint ?? "—")) }
    }
}
