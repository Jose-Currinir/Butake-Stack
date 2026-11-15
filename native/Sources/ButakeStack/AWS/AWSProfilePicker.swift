import SwiftUI

/// «Perfil de AWS» in a project's environment: sets `AWS_PROFILE` (and `AWS_REGION` when the
/// profile has one) as plain, non-secret variables of the environment being edited. The change is
/// part of the draft: it is written with «Guardar», like any other variable. In Production it asks
/// first, saying which account the profile reaches.
struct AWSProfilePicker: View {
    @Binding var rows: [EnvironmentsView.Row]
    let production: Bool
    let changed: () -> Void
    @Bindable private var tool = AWSTool.shared
    @State private var pending: AWSProfile?

    private var current: String { rows.first { $0.key == "AWS_PROFILE" && !$0.secret }?.value ?? "" }

    var body: some View {
        Picker(L("aws.env.picker"), selection: Binding(get: { current }, set: choose)) {
            Text(L("aws.env.none")).tag("")
            ForEach(tool.profiles) { Text(verbatim: $0.name).tag($0.name) }
            if !current.isEmpty && tool.profile(current) == nil {
                Text(String(format: L("aws.env.unknown"), current)).tag(current)
            }
        }
        .help(L("aws.env.help"))
        .accessibilityIdentifier("env.awsProfile")
        .task { if !tool.loaded { await tool.load() } }
        .confirmationDialog(String(format: L("aws.env.productionConfirm"), pending?.name ?? ""),
                            isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } }),
                            presenting: pending) { profile in
            Button(L("aws.env.use")) { apply(profile) }.accessibilityIdentifier("env.awsProfile.confirm")
            Button(L("common.cancel"), role: .cancel) {}
        } message: { profile in
            Text(profile.account.map { String(format: L("aws.env.productionAccount"), $0) } ?? L("aws.env.productionNoAccount"))
        }
    }

    private func choose(_ name: String) {
        guard let profile = tool.profile(name) else { return apply(nil) }
        if production { pending = profile } else { apply(profile) }
    }

    private func apply(_ profile: AWSProfile?) {
        let previousRegion = tool.profile(current)?.region
        set("AWS_PROFILE", profile?.name)
        if let region = profile?.region {
            set("AWS_REGION", region)
        } else if let previousRegion, rows.contains(where: { $0.key == "AWS_REGION" && $0.value == previousRegion }) {
            set("AWS_REGION", nil)
        }
        changed()
    }

    private func set(_ key: String, _ value: String?) {
        if let index = rows.firstIndex(where: { $0.key == key && !$0.secret }) {
            if let value { rows[index].value = value } else { rows.remove(at: index) }
        } else if let value, !rows.contains(where: { $0.key == key }) {
            rows.append(EnvironmentsView.Row(key: key, value: value, secret: false))
        }
    }
}
