import SwiftUI

extension AWSProfile: CloudAccount {}

/// The AWS tool's profiles in the window's content column, a section per kind of credential.
struct AWSProfileList: View {
    @Bindable var tool: AWSTool

    var body: some View {
        CloudAccountList(accounts: tool.profiles, selection: $tool.selection, loaded: tool.loaded,
                         searchPrompt: L("aws.search"), identifier: "aws.list",
                         sectionTitle: { L("aws.section.\($0.rawValue)") }) { profile in
            CloudAccountRow(symbol: profile.kind.symbol, title: profile.name, subtitle: subtitle(profile),
                            attention: attention(profile), identifier: "aws.list.profile.\(profile.name)")
        } bar: {
            Button { tool.sheet = .new } label: { Label(L("aws.newEllipsis"), systemImage: Symbols.newProfile) }
                .buttonStyle(.borderless).help(L("aws.newHelp")).accessibilityIdentifier("aws.list.new")
        }
    }

    /// Default, account and region; the kind when the files say none of them.
    private func subtitle(_ profile: AWSProfile) -> String {
        var parts: [String] = []
        if profile.isDefault { parts.append(L("aws.default")) }
        if let account = profile.account { parts.append(account) }
        if let region = profile.region { parts.append(region) }
        return parts.isEmpty ? profile.kind.title : parts.joined(separator: " · ")
    }

    /// What needs the user: an expired session, keys in plain text, a credential process to repair.
    private func attention(_ profile: AWSProfile) -> String? {
        if profile.duplicated { return L("aws.duplicated") }
        if profile.needsRepair { return L("aws.helper.missing") }
        if profile.session.map({ !$0.valid }) == true { return L("aws.session.expired") }
        if profile.keyFile != nil { return L("aws.plainText") }
        return nil
    }
}
