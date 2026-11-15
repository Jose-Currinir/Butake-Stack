import Foundation

/// The rows of «Firma», one platform at a time (see `VaultSigning`).
extension VaultSigning.Context {
    // MARK: Android

    func androidRows() -> [VaultSigning.Row] {
        var rows = [keystoreRow(), playAccountRow()]
        if usesFirebase { rows.insert(googleServicesRow(), at: 1); rows.append(firebaseAppIdRow()) }
        return rows
    }

    private func keystoreRow() -> VaultSigning.Row {
        let title = L("vault.signing.keystore")
        let keystores = here(.androidKeystore).sorted { rank($0) < rank($1) }
        guard let best = keystores.first else {
            return row("keystore", .android, title, .missing, L("vault.signing.keystore.none"), advice: L("vault.signing.keystore.add"), add: .androidKeystore)
        }
        if let problem = problemRow("keystore", .android, title, best) { return problem }
        let meta = best.metadata
        let parts = [best.name, meta.value("vault.meta.alias").map { String(format: L("vault.signing.alias"), $0) },
                     (meta.value("vault.meta.sha256").map { "SHA-256 " + VaultSigning.short($0) } ?? meta.value("vault.meta.sha1").map { "SHA-1 " + VaultSigning.short($0) }),
                     expiryText(best)].compactMap { $0 }
        return row("keystore", .android, title, dated(best), parts.joined(separator: " · "), advice: L("vault.signing.advice.renew"), item: best.id)
    }

    private func googleServicesRow() -> VaultSigning.Row {
        let title = "google-services.json"
        let files = here(.googleServices)
        func packages(_ item: VaultItem) -> [String] {
            (item.metadata.value("vault.meta.packages") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        guard !files.isEmpty else {
            return row("googleServices", .android, title, .missing, L("vault.signing.firebase.none"), advice: L("vault.signing.firebase.add"), add: .googleServices)
        }
        guard let bundle = app.bundleId else {
            return row("googleServices", .android, title, .ready, files[0].name + " · " + packages(files[0]).joined(separator: ", "), item: files[0].id)
        }
        if let fit = files.first(where: { packages($0).contains { VaultSigning.accepts($0, bundle: bundle, environment: environment) } }) {
            let package = packages(fit).first { VaultSigning.accepts($0, bundle: bundle, environment: environment) } ?? bundle
            let project = fit.metadata.value("vault.meta.projectId").map { " · " + String(format: L("vault.signing.project"), $0) } ?? ""
            return row("googleServices", .android, title, .ready, "\(fit.name) · \(package)\(project)", item: fit.id)
        }
        let found = packages(files[0])
        return row("googleServices", .android, title, .mismatch,
                   found.isEmpty ? L("vault.meta.unreadable") : String(format: L("vault.signing.otherPackage"), found.joined(separator: ", "), bundle),
                   advice: L("vault.signing.firebase.replace"), item: files[0].id)
    }

    private func playAccountRow() -> VaultSigning.Row {
        let title = L("vault.signing.play")
        let own = items.filter { $0.kind == .serviceAccount && current($0) && [nil, .android, .terceros].contains($0.section) }
        let shared = shared(.serviceAccount, VaultBackupLayout.isPlayService)
        guard let account = own.first.map({ ($0, nil as String?) }) ?? shared.first.map({ ($0.0, Optional($0.1)) }) else {
            return row("play", .android, title, .missing, L("vault.signing.play.none"), advice: L("vault.signing.play.add"), add: .serviceAccount)
        }
        let parts = [account.0.metadata.value("vault.meta.clientEmail") ?? account.0.name,
                     account.1.map { String(format: L("vault.signing.sharedIn"), "_SERVICIOS/\($0)") }].compactMap { $0 }
        return problemRow("play", .android, title, account.0) ?? row("play", .android, title, .ready, parts.joined(separator: " · "), item: account.0.id)
    }

    private func firebaseAppIdRow() -> VaultSigning.Row {
        let title = L("vault.signing.firebaseAppId")
        func value(_ item: VaultItem) -> String { item.field(.token)?.value ?? item.fields.first?.value ?? "" }
        let ids = items.filter { VaultSigning.isFirebaseAppId($0) && current($0) && !value($0).contains(":ios:") && $0.section != .ios }
        guard let id = ids.first else {
            return row("firebaseAppId", .android, title, .missing, L("vault.signing.firebaseAppId.none"), advice: L("vault.signing.firebaseAppId.add"), add: .token)
        }
        // «1:<número del proyecto>:android:<…>»: checked against google-services.json, never shown.
        let parts = value(id).split(separator: ":").map(String.init)
        guard parts.count == 4, parts[2] == "android" else {
            return row("firebaseAppId", .android, title, .mismatch, L("vault.signing.firebaseAppId.shape"), advice: L("vault.signing.advice.fix"), item: id.id)
        }
        let numbers = Set(here(.googleServices).compactMap { $0.metadata.value("vault.meta.projectNumber") })
        if !numbers.isEmpty && !numbers.contains(parts[1]) {
            return row("firebaseAppId", .android, title, .mismatch, L("vault.signing.firebaseAppId.project"), advice: L("vault.signing.advice.fix"), item: id.id)
        }
        return row("firebaseAppId", .android, title, .ready, L("vault.signing.present"), item: id.id)
    }

    /// Readable first, then the latest to expire.
    private func rank(_ item: VaultItem) -> (Int, TimeInterval) {
        (item.metadata.problem == nil ? 0 : 1, -(item.metadata.expires ?? .distantPast).timeIntervalSince1970)
    }

    // MARK: iOS

    func iosRows() -> [VaultSigning.Row] {
        var rows = profileRows()
        rows.append(appStoreKeyRow())
        if usesFirebase { rows.append(googleServiceInfoRow()) }
        return rows
    }

    /// Certificates the vault can sign with, by SHA-1: a readable `.p12`, or a `.cer` kept beside its key.
    private var identities: [String: VaultItem] {
        var out: [String: VaultItem] = [:]
        for item in index.items where item.kind == .iosCertificate && item.metadata.problem == nil {
            guard let sha1 = item.metadata.value("vault.meta.sha1"), let file = item.files.first?.name else { continue }
            if file.lowercased().hasSuffix(".cer") {
                let stem = (file as NSString).deletingPathExtension
                guard index.items(in: item.container).contains(where: { $0.kind == .certificateKey && $0.files.contains { ($0.name as NSString).deletingPathExtension == stem } }) else { continue }
            }
            out[sha1] = out[sha1] ?? item
        }
        return out
    }

    private func profileRows() -> [VaultSigning.Row] {
        let profiles = here(.provisioningProfile)
        let main = app.bundleId
        var bundles = Set(profiles.compactMap(VaultSigning.bundle))
        if let main { bundles.insert(main) }
        let ordered = bundles.sorted { a, b in a == main ? true : b == main ? false : a < b }
        let identities = identities
        let locked = index.items.filter { $0.kind == .iosCertificate && ["vault.meta.needsPassword", "vault.meta.wrongPassword"].contains($0.metadata.problem) }
        var rows: [VaultSigning.Row] = []
        for bundle in ordered {
            let title = String(format: L("vault.signing.profile"), bundle)
            let own = profiles.filter { VaultSigning.bundle(of: $0) == bundle || (bundle == main && VaultSigning.bundle(of: $0) == "*") }
            guard !own.isEmpty else {
                rows.append(row("profile.\(bundle)", .ios, title, .missing, L("vault.signing.profile.none"), advice: L("vault.signing.profile.add"), add: .provisioningProfile))
                continue
            }
            let checked = own.map { profileRow($0, title: title, bundle: bundle, identities: identities, locked: locked) }
            rows.append(checked.min { ($0.status, $0.detail) < ($1.status, $1.detail) } ?? checked[0])
        }
        return rows
    }

    private func profileRow(_ profile: VaultItem, title: String, bundle: String, identities: [String: VaultItem], locked: [VaultItem]) -> VaultSigning.Row {
        let id = "profile.\(bundle)"
        if let problem = problemRow(id, .ios, title, profile) { return problem }
        let meta = profile.metadata
        if environment == .prod && meta.value("vault.meta.profileType") == "development" {
            return row(id, .ios, title, .mismatch, "\(profile.name) · \(L("vault.signing.profile.development"))", advice: L("vault.signing.profile.replace"), item: profile.id)
        }
        if environment == .prod && meta.value("vault.meta.push") == "development" {
            return row(id, .ios, title, .mismatch, "\(profile.name) · \(L("vault.signing.profile.pushDevelopment"))", advice: L("vault.signing.profile.replace"), item: profile.id)
        }
        let certificates = (meta.value("vault.meta.certificates") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !certificates.isEmpty else {
            return row(id, .ios, title, .missing, "\(profile.name) · \(L("vault.signing.profile.unread"))", advice: L("vault.signing.advice.reread"), item: profile.id)
        }
        guard let identity = certificates.compactMap({ identities[$0] }).min(by: { rank($0) < rank($1) }) else {
            if !locked.isEmpty {
                return row(id, .ios, title, .missing, "\(profile.name) · \(L("vault.signing.profile.locked"))", advice: L("vault.signing.advice.complete"), item: locked[0].id)
            }
            return row(id, .ios, title, .mismatch, "\(profile.name) · " + String(format: L("vault.signing.profile.noCertificate"), certificates.count),
                       advice: String(format: L("vault.signing.profile.addCertificate"), VaultSigning.short(certificates[0])), item: profile.id)
        }
        let subject = identity.metadata.value("vault.meta.subject") ?? identity.name
        let parts = [profile.name, expiryText(profile), String(format: L("vault.signing.signsWith"), subject), meta.value("vault.meta.entitlements")].compactMap { $0 }
        return row(id, .ios, title, max(dated(profile), dated(identity)), parts.joined(separator: " · "), advice: L("vault.signing.advice.renew"), item: profile.id)
    }

    private func appStoreKeyRow() -> VaultSigning.Row {
        let title = L("vault.kind.appStoreKey")
        let shared = shared(.appStoreKey, VaultBackupLayout.isAppStoreService)
        let keys = here(.appStoreKey).map { ($0, nil as String?) } + shared.map { ($0.0, Optional($0.1)) }
        func complete(_ item: VaultItem) -> Bool { item.field(.keyId)?.value.isEmpty == false && item.field(.issuerId)?.value.isEmpty == false }
        guard let key = keys.first(where: { complete($0.0) }) ?? keys.first else {
            return row("appStoreKey", .ios, title, .missing, L("vault.signing.appStoreKey.none"), advice: L("vault.signing.appStoreKey.add"), add: .appStoreKey)
        }
        let keyId = key.0.field(.keyId)?.value ?? ""
        guard complete(key.0) else {
            return row("appStoreKey", .ios, title, .missing, "\(key.0.name) · \(L(keyId.isEmpty ? "vault.signing.appStoreKey.noKeyId" : "vault.signing.appStoreKey.noIssuer"))",
                       advice: L("vault.signing.advice.complete"), item: key.0.id)
        }
        let parts = ["Key ID \(keyId)", L("vault.signing.appStoreKey.issuer"), key.1.map { String(format: L("vault.signing.sharedIn"), "_SERVICIOS/\($0)") }].compactMap { $0 }
        return row("appStoreKey", .ios, title, .ready, parts.joined(separator: " · "), item: key.0.id)
    }

    private func googleServiceInfoRow() -> VaultSigning.Row {
        let title = "GoogleService-Info.plist"
        let files = here(.googleServiceInfo)
        guard let first = files.first else {
            return row("googleServiceInfo", .ios, title, .missing, L("vault.signing.firebase.none"), advice: L("vault.signing.firebase.add"), add: .googleServiceInfo)
        }
        guard let main = app.bundleId else { return row("googleServiceInfo", .ios, title, .ready, first.name, item: first.id) }
        if let fit = files.first(where: { $0.metadata.value("vault.meta.bundleId").map { VaultSigning.accepts($0, bundle: main, environment: environment) } == true }) {
            return row("googleServiceInfo", .ios, title, .ready, "\(fit.name) · \(fit.metadata.value("vault.meta.bundleId") ?? main)", item: fit.id)
        }
        let found = first.metadata.value("vault.meta.bundleId")
        return row("googleServiceInfo", .ios, title, .mismatch,
                   found.map { String(format: L("vault.signing.otherPackage"), $0, main) } ?? L("vault.meta.unreadable"),
                   advice: L("vault.signing.firebase.replace"), item: first.id)
    }
}
