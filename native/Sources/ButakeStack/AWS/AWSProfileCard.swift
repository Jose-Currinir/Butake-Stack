import SwiftUI

/// A profile's card in the detail: who it is (after «Comprobar»), its settings, its credentials
/// (kind and last four characters, never a secret), its sign-in session and the projects that use it.
struct AWSProfileCard: View {
    @Bindable var tool: AWSTool
    let profile: AWSProfile

    var body: some View {
        Form {
            Section {
                header
                notices
            }
            identity
            if profile.kind == .sso { AWSSessionSection(tool: tool, profile: profile) }
            Section(L("aws.configuration")) {
                InfoRow(title: L("aws.region"), value: profile.region ?? L("aws.noRegion"))
                InfoRow(title: L("aws.output"), value: profile.output ?? L("aws.outputDefault"))
                if let account = profile.account { InfoRow(title: L("aws.account"), value: account, mono: true) }
                kindRows
            }
            credentials
            projects
            Section(L("aws.files")) {
                if let state = tool.state {
                    InfoRow(title: L("aws.configFile"), value: state.configPath, mono: true)
                    InfoRow(title: L("aws.credentialsFile"), value: state.credentialsPath, mono: true)
                }
            }
        }
        .formStyle(.grouped).themedScroll()
        .accessibilityIdentifier("aws.card")
        // Another profile chosen or the page left: what waits on this one stops with it.
        .onDisappear { tool.cancelWaits(for: profile.name) }
    }

    private var header: some View {
        CloudCardHeader(symbol: profile.kind.symbol, title: profile.name, subtitle: profile.kind.title, titleIdentifier: "aws.card.name") {
            if profile.isDefault { Chip(text: L("aws.default"), symbol: Symbols.makeDefault) }
        }
    }

    @ViewBuilder private var notices: some View {
        if !tool.cliInstalled {
            Notice(.warning, L("aws.cliMissing"), detail: L("aws.cliMissingDetail")) {
                Button { StackStore.shared.route = UtilityCatalog.route(for: "aws") } label: { Label(L("aws.openUtilities"), systemImage: Symbols.utilities) }
                    .buttonStyle(.bordered).accessibilityIdentifier("aws.card.utilities")
            }
        }
        if profile.duplicated { Notice(.error, L("aws.duplicated"), detail: L("aws.duplicatedDetail")) }
        if profile.needsRepair {
            Notice(.warning, L(profile.helper == "other" ? "aws.helper.other" : "aws.helper.missing"), detail: L("aws.helper.detail")) {
                Button { tool.repairing = profile } label: { Label(L("aws.repairEllipsis"), systemImage: Symbols.repair) }
                    .buttonStyle(.bordered).disabled(StackStore.shared.busy != nil).accessibilityIdentifier("aws.card.repair")
            }
        }
    }

    @ViewBuilder private var identity: some View {
        Section {
            if tool.checking.contains(profile.name) {
                LabeledContent(L("aws.identity.checking")) {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        AWSLateCancelButton(id: "aws.identity.cancel") { tool.cancelCheck(profile.name) }
                    }
                }
            } else if let found = tool.identities[profile.name] {
                // The account once per screen: here only when the files do not say it, or say another one.
                if profile.account == nil {
                    InfoRow(title: L("aws.account"), value: found.account, mono: true)
                } else if profile.account != found.account {
                    Notice(.warning, String(format: L("aws.identity.otherAccount"), found.account))
                }
                if let arn = found.arn { InfoRow(title: L("aws.identity.arn"), value: arn, mono: true, lines: 2) }
            } else if let error = tool.checkErrors[profile.name] {
                Notice(.error, error)
            } else {
                Text(L("aws.identity.unchecked")).foregroundStyle(.secondary)
            }
        } header: {
            Text(L("aws.identity"))
        } footer: {
            SettingsFooter(L("aws.identity.footer"))
        }
    }

    @ViewBuilder private var kindRows: some View {
        switch profile.kind {
        case .sso:
            if let session = profile.ssoSession { InfoRow(title: L("aws.sso.session"), value: session) }
            if let url = profile.ssoStartUrl { InfoRow(title: L("aws.sso.startUrl"), value: url, mono: true) }
            if let role = profile.roleName { InfoRow(title: L("aws.sso.role"), value: role) }
        case .role:
            if let arn = profile.roleArn { InfoRow(title: L("aws.role.arn"), value: arn, mono: true, lines: 2) }
            InfoRow(title: L("aws.role.source"), value: profile.sourceProfile ?? profile.credentialSource ?? "—")
        default:
            EmptyView()
        }
    }

    @ViewBuilder private var credentials: some View {
        Section {
            InfoRow(title: L("aws.credentials.kind"), value: credentialKind)
            if let suffix = profile.keySuffix {
                InfoRow(title: L("aws.credentials.keyId"), value: "••••" + suffix, mono: true)
            }
            if let file = profile.keyFile {
                Notice(.warning, L("aws.plainText"), detail: String(format: L("aws.plainTextDetail"), file))
            }
        } header: {
            Text(L("aws.credentials"))
        } footer: {
            if profile.inKeychain { SettingsFooter(L("aws.credentials.keychainFooter")) }
        }
    }

    private var credentialKind: String {
        if profile.inKeychain { return L("aws.credentials.keychain") }
        if profile.kind == .static && profile.temporary { return L("aws.credentials.temporary") }
        return profile.kind.title
    }

    private var projects: some View {
        Section(L("aws.projects")) {
            if profile.projects.isEmpty {
                Text(L("aws.projects.none")).foregroundStyle(.secondary)
            }
            ForEach(profile.projects, id: \.self) { use in
                if let project = StackStore.shared.projects.first(where: { $0.id == use.project }) {
                    ProjectLinkRow(project: project, detail: use.environmentName) { StackStore.shared.openSite(project.id) }
                        .accessibilityIdentifier("aws.card.project.\(use.project).\(use.environment)")
                }
            }
        }
    }
}
