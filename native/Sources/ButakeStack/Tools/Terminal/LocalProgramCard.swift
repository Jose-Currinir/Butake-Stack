import SwiftUI

/// The card of a program of this Mac, the detail while none of its sessions is shown: what it is,
/// its version and file, the folder it starts in, and «Abrir».
struct LocalProgramCard: View {
    let program: LocalProgram
    @Bindable var workspace: SSHWorkspace

    private var file: String { program.executable ?? LocalConsoles.loginShell() }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 12) {
                    LocalProgramTile(program: program, size: 36)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(program.title).font(.uiTitle3.weight(.semibold)).lineLimit(2)
                            .accessibilityIdentifier("ssh.local.card.name")
                        Text(program.detail).font(.uiCallout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    Spacer(minLength: 8)
                }
            }
            Section {
                if let version = program.version { InfoRow(title: L("ssh.local.version"), value: version) }
                DisclosureGroup(L("ssh.local.options")) {
                    InfoRow(title: L("ssh.local.file"), value: (file as NSString).abbreviatingWithTildeInPath, mono: true)
                    InfoRow(title: L("ssh.local.folder"), value: L("ssh.local.homeFolder"))
                        .help(NSHomeDirectory())
                }
                .accessibilityIdentifier("ssh.local.card.options")
                LabeledContent {
                    HStack(spacing: 8) {
                        Button { if let folder = LocalConsoles.chooseFolder() { workspace.openLocal(program, directory: folder) } } label: {
                            Label(L("ssh.local.openInFolderEllipsis"), systemImage: Symbols.folder)
                        }
                        .buttonStyle(.bordered).accessibilityIdentifier("ssh.local.card.openInFolder")
                        Button { workspace.openLocal(program) } label: { Label(L("ssh.local.open"), systemImage: Symbols.terminal) }
                            .buttonStyle(.borderedProminent).accessibilityIdentifier("ssh.local.card.open")
                    }
                } label: { EmptyView() }
            } footer: {
                SettingsFooter(L("ssh.local.footer"))
            }
        }
        .formStyle(.grouped).themedScroll()
        .accessibilityIdentifier("ssh.local.card")
    }
}
