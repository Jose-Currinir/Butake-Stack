import SwiftUI

/// The AWS tool's detail: the selected profile's card, or why there is none (AWS CLI missing, no
/// profiles, nothing selected). Its actions live in the toolbar: «Comprobar» with its title, a new
/// profile, and the rest in «Más».
struct AWSPage: View {
    @Bindable var store: StackStore
    @Bindable var tool = AWSTool.shared

    var body: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar { toolbar }
            .onDisappear { tool.cancelAll() }
            .task {
                await tool.load()
                #if DEBUG
                await QAHooks.aws(tool)
                #endif
            }
            .sheet(item: $tool.sheet) { sheet in
                switch sheet {
                case .new: AWSProfileSheet(tool: tool, original: nil).themedSheet()
                case .edit(let profile): AWSProfileSheet(tool: tool, original: profile).themedSheet()
                case .duplicate(let profile): AWSNameSheet(tool: tool, kind: .duplicate, profile: profile).themedSheet()
                case .makeDefault(let profile): AWSNameSheet(tool: tool, kind: .makeDefault, profile: profile).themedSheet()
                }
            }
            .confirmationDialog(String(format: L("aws.deleteConfirm"), tool.deleting?.name ?? ""),
                                isPresented: Binding(get: { tool.deleting != nil }, set: { if !$0 { tool.deleting = nil } }),
                                presenting: tool.deleting) { profile in
                Button(L("aws.delete"), role: .destructive) { Task { await tool.delete(profile) } }
                    .accessibilityIdentifier("aws.confirmDelete")
                Button(L("common.cancel"), role: .cancel) {}
            } message: { profile in
                Text(deleteDetail(profile))
            }
            .confirmationDialog(L("aws.signOutConfirm"), isPresented: $tool.signingOut) {
                Button(L("aws.signOut"), role: .destructive) { tool.startSignOut() }
                    .accessibilityIdentifier("aws.confirmSignOut")
                Button(L("common.cancel"), role: .cancel) {}
            } message: {
                Text(L("aws.signOutDetail"))
            }
            .confirmationDialog(String(format: L("aws.repairConfirm"), tool.repairing?.name ?? ""),
                                isPresented: Binding(get: { tool.repairing != nil }, set: { if !$0 { tool.repairing = nil } }),
                                presenting: tool.repairing) { profile in
                Button(L("aws.repair")) { Task { await tool.repair(profile) } }
                    .accessibilityIdentifier("aws.confirmRepair")
                Button(L("common.cancel"), role: .cancel) {}
            } message: { _ in
                Text(L("aws.repairDetail"))
            }
    }

    private func deleteDetail(_ profile: AWSProfile) -> String {
        var lines = [L(profile.inKeychain ? "aws.deleteDetailKeychain" : "aws.deleteDetail")]
        if !profile.projects.isEmpty {
            lines.append(String(format: L("aws.deleteUsed"), profile.projects.map(\.projectName).joined(separator: ", ")))
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder private var content: some View {
        if let profile = tool.selected {
            AWSProfileCard(tool: tool, profile: profile).id(profile.name)
        } else if !tool.loaded {
            ProgressView()
        } else if !tool.cliInstalled && tool.profiles.isEmpty {
            ContentUnavailableView {
                Label(L("aws.cliMissing"), systemImage: Symbols.utilities)
            } description: {
                Text(L("aws.cliMissingDetail"))
            } actions: {
                Button { store.route = UtilityCatalog.route(for: "aws") } label: { Label(L("aws.openUtilities"), systemImage: Symbols.utilities) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("aws.empty.utilities")
            }
        } else if tool.loadFailed {
            ContentUnavailableView {
                Label(L("aws.loadFailed"), systemImage: Symbols.error)
            } actions: {
                Button { Task { await tool.load() } } label: { Label(L("common.retry"), systemImage: Symbols.reload) }
                    .buttonStyle(.bordered).accessibilityIdentifier("aws.empty.retry")
            }
        } else if tool.profiles.isEmpty {
            ContentUnavailableView {
                Label(L("aws.empty"), systemImage: Symbols.awsProfile)
            } description: {
                Text(L("aws.emptyDetail"))
            } actions: {
                Button { tool.sheet = .new } label: { Label(L("aws.newEllipsis"), systemImage: Symbols.newProfile) }
                    .buttonStyle(.borderedProminent).accessibilityIdentifier("aws.empty.new")
            }
        } else {
            ContentUnavailableView(L("aws.noSelection"), systemImage: Symbols.awsProfile, description: Text(L("aws.noSelectionDetail")))
        }
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItemGroup(placement: .primaryAction) {
            Button { tool.sheet = .new } label: { Label(L("aws.newEllipsis"), systemImage: Symbols.newProfile) }
                .help(L("aws.newHelp")).accessibilityIdentifier("aws.toolbar.new")
            Button {
                if let profile = tool.selected { tool.startCheck(profile) }
            } label: { Label(L("aws.check"), systemImage: Symbols.checkIdentity) }
                .labelStyle(.titleAndIcon).font(nil).buttonStyle(.borderedProminent)
                .disabled(tool.selected == nil || !tool.cliInstalled || tool.checking.contains(tool.selection ?? ""))
                .keyboardShortcut("k", modifiers: [.command, .shift])
                .help(L("aws.checkHelp")).accessibilityIdentifier("aws.toolbar.check")
            Menu {
                if let profile = tool.selected { AWSProfileMenu(tool: tool, profile: profile) }
            } label: { Label(L("aws.more"), systemImage: Symbols.more) }
                .disabled(tool.selected == nil)
                .help(L("aws.more")).accessibilityIdentifier("aws.toolbar.more")
        }
    }
}

/// The actions on a profile, in the toolbar's «Más».
struct AWSProfileMenu: View {
    let tool: AWSTool
    let profile: AWSProfile
    var body: some View {
        Button { tool.sheet = .edit(profile) } label: { Label(L("aws.editEllipsis"), systemImage: Symbols.edit) }
            .disabled(profile.duplicated).accessibilityIdentifier("aws.menu.edit")
        Button { tool.sheet = .duplicate(profile) } label: { Label(L("aws.duplicateEllipsis"), systemImage: Symbols.copy) }
            .disabled(profile.duplicated || profile.hasKeys)
            .help(profile.hasKeys ? L("aws.duplicateHasKeys") : "")
            .accessibilityIdentifier("aws.menu.duplicate")
        Button { tool.sheet = .makeDefault(profile) } label: { Label(L("aws.makeDefaultEllipsis"), systemImage: Symbols.makeDefault) }
            .disabled(profile.isDefault || profile.duplicated).accessibilityIdentifier("aws.menu.default")
        if profile.needsRepair {
            Button { tool.repairing = profile } label: { Label(L("aws.repairEllipsis"), systemImage: Symbols.repair) }
                .accessibilityIdentifier("aws.menu.repair")
        }
        Divider()
        Button(role: .destructive) { tool.deleting = profile } label: { Label(L("aws.deleteEllipsis"), systemImage: Symbols.delete) }
            .disabled(profile.duplicated).accessibilityIdentifier("aws.menu.delete")
    }
}
