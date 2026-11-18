import SwiftUI

/// Chooses a project's fixed address (P-35): the Cloudflare zone and the name in it, proposed as
/// `<proyecto>-test.<zona>` (one level under the zone, covered by Cloudflare's universal
/// certificate). A deeper name is allowed, with the warning that it needs an advanced certificate.
struct FixedAddressSheet: View {
    enum Mode: String, Identifiable { case configure, change; var id: String { rawValue } }
    let store: StackStore
    let project: Project
    let mode: Mode
    @State var zone: String
    /// The address now, when changing it.
    let current: String?
    let done: (TunnelChange) -> Void
    @State private var hostname = ""
    /// The user wrote the name: a new zone no longer replaces it.
    @State private var edited = false

    init(store: StackStore, project: Project, mode: Mode, zone: String, current: String?, done: @escaping (TunnelChange) -> Void) {
        self.store = store; self.project = project; self.mode = mode; self.current = current; self.done = done
        _zone = State(initialValue: zone)
    }

    private var cleanZone: String { zone.trimmingCharacters(in: .whitespaces).lowercased() }
    private var cleanHost: String { hostname.trimmingCharacters(in: .whitespaces).lowercased() }
    private static func label(_ part: Substring) -> Bool {
        !part.isEmpty && part.count <= 63 && !part.hasPrefix("-") && !part.hasSuffix("-")
            && part.allSatisfy { ($0.isASCII && $0.isLowercase) || $0.isNumber || $0 == "-" }
    }
    private var zoneValid: Bool {
        let parts = cleanZone.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count >= 2 && parts.allSatisfy(Self.label) && parts.last != "test"
    }
    /// The part of the name before the zone (nil when the name is not in it).
    private var prefix: Substring? {
        guard zoneValid, cleanHost.hasSuffix("." + cleanZone) else { return nil }
        let head = cleanHost.dropLast(cleanZone.count + 1)
        return head.split(separator: ".", omittingEmptySubsequences: false).allSatisfy(Self.label) ? head : nil
    }
    private var problem: String? {
        if !cleanZone.isEmpty && !zoneValid { return L("error.invalid_zone") }
        if !cleanHost.isEmpty && zoneValid && prefix == nil { return L("error.public_hostname_outside_zone") }
        if mode == .change && cleanHost == current { return L("error.public_hostname_unchanged") }
        return nil
    }
    private var advanced: Bool { prefix?.contains(".") == true }

    var body: some View {
        SheetFrame(title: mode == .configure ? L("share.fixed.sheet.configure") : L("share.fixed.sheet.change"),
                   symbol: Symbols.address, detail: String(format: L("share.fixed.sheet.detail"), project.title),
                   note: mode == .configure ? L("share.fixed.sheet.note") : L("share.fixed.sheet.changeNote"), width: 520,
                   actionTitle: mode == .configure ? L("share.fixed.sheet.create") : L("share.fixed.sheet.save"),
                   actionSymbol: Symbols.address, actionID: "share.fixed.sheet.save",
                   canAct: prefix != nil && problem == nil && store.busy == nil, cancelID: "share.fixed.sheet.cancel") {
            guard let change = await store.saveFixedAddress(project, hostname: cleanHost, zone: mode == .configure ? cleanZone : nil) else {
                return false
            }
            done(change)
            return true
        } content: {
            Form {
                TextField(L("share.fixed.sheet.zone"), text: $zone, prompt: Text(L("share.fixed.sheet.zonePrompt")))
                    .disabled(mode == .change)
                    .help(L("share.fixed.sheet.zoneHelp"))
                    .accessibilityIdentifier("share.fixed.sheet.zone")
                TextField(L("share.fixed.sheet.hostname"), text: Binding(get: { hostname }, set: { hostname = $0; edited = true }),
                          prompt: Text(verbatim: "\(project.id)-test.\(zoneValid ? cleanZone : "…")"))
                    .accessibilityIdentifier("share.fixed.sheet.hostname")
                if let problem {
                    Notice(.error, problem)
                } else if advanced {
                    Notice(.warning, L("share.fixed.advancedCertificate"), detail: L("share.fixed.advancedCertificateDetail"))
                }
            }
            .formStyle(.grouped).scrollDisabled(true)
        }
        .onAppear { if let current { hostname = current; edited = true } else { propose() } }
        .onChange(of: zone) { _, _ in if !edited { propose() } }
    }

    /// `<proyecto>-test.<zona>`, as the engine proposes it.
    private func propose() {
        hostname = zoneValid ? "\(project.id)-test.\(cleanZone)" : ""
    }
}
