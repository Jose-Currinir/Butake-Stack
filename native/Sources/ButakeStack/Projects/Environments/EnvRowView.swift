import SwiftUI

/// One variable: its name, its value (masked when secret) and its actions at the end of the row.
struct EnvRowView: View {
    @Binding var row: EnvironmentsView.Row
    let revealed: String?
    let hasSecret: Bool
    let changed: () -> Void
    let reveal: () -> Void
    let copy: () -> Void
    let edit: () -> Void
    let toggleSecret: () -> Void
    let remove: () -> Void
    /// Projects with a port of their own, for `{port:<id>}` (another project's address).
    let ports: [Project]
    var body: some View {
        LabeledContent {
            HStack(spacing: 8) {
                if row.secret {
                    Image(systemName: Symbols.locked).font(.uiCaption).foregroundStyle(.secondary).accessibilityHidden(true)
                    Text(revealed ?? (row.newSecret != nil ? L("env.secretChanged") : (hasSecret ? "••••••••••••" : L("env.secretEmpty"))))
                        .font(.uiCallout.monospaced()).foregroundStyle(revealed == nil ? .secondary : .primary)
                        .textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    action(L("env.reveal"), revealed == nil ? "eye" : "eye.slash", "reveal", reveal).disabled(!hasSecret)
                    action(L("env.copy"), Symbols.copy, "copy", copy).disabled(!hasSecret)
                    action(L("env.setSecret"), "pencil", "edit", edit)
                } else {
                    TextField(L("env.valuePlaceholder"), text: $row.value, prompt: Text(L("env.valuePlaceholder")))
                        .labelsHidden().font(.uiCallout.monospaced()).multilineTextAlignment(.trailing)
                        .onChange(of: row.value) { _, _ in changed() }
                        .accessibilityIdentifier("env.value.\(row.key)")
                    if !ports.isEmpty { portMenu }
                    action(L("env.makeSecret"), "lock.open", "secret", toggleSecret)
                }
                action(L("env.removeKey"), Symbols.remove, "remove", remove)
            }
        } label: {
            if row.original == nil {
                TextField(L("env.keyPlaceholder"), text: $row.key, prompt: Text(L("env.keyPlaceholder")))
                    .labelsHidden().font(.uiSubheadline.weight(.semibold).monospaced())
                    .onChange(of: row.key) { _, _ in changed() }
                    .accessibilityIdentifier("env.newKey")
            } else {
                Text(row.key).font(.uiSubheadline.weight(.semibold).monospaced()).textSelection(.enabled)
            }
        }
    }
    /// Inserts `{port:<id>}`: Stack puts that project's port there when the environment is applied.
    private var portMenu: some View {
        Menu {
            ForEach(ports) { project in
                Button { row.value += "{port:\(project.id)}"; changed() } label: {
                    Text(verbatim: "\(project.title) · \(project.upstream.map(String.init) ?? "")")
                }
                .accessibilityIdentifier("env.port.\(row.key).\(project.id)")
            }
        } label: {
            Label(L("env.insertPort"), systemImage: Symbols.link).labelStyle(.iconOnly)
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help(L("env.insertPortHelp"))
        .accessibilityIdentifier("env.port.\(row.key)")
    }
    /// An action at the end of the row: icon only, with its name in the tooltip.
    private func action(_ title: String, _ symbol: String, _ id: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) { Label(title, systemImage: symbol).labelStyle(.iconOnly) }
            .buttonStyle(.borderless).help(title).accessibilityIdentifier("env.\(id).\(row.key)")
    }
}
