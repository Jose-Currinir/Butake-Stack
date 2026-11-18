import SwiftUI

/// An account of a cloud tool as its list shows it: an AWS profile, a Google Cloud account. Its id
/// is what the list selects (the profile's name, the account's address).
protocol CloudAccount: Identifiable where ID == String {
    associatedtype Kind: CaseIterable & Hashable where Kind.AllCases: RandomAccessCollection
    var kind: Kind { get }
    func matches(_ text: String) -> Bool
}

/// The content column of a cloud tool (AWS, Google Cloud): its accounts in a section per kind, the
/// search field, the waits and empty results, and a bar at the bottom with the tool's own button.
struct CloudAccountList<Account: CloudAccount, Row: View, Bar: View>: View {
    let accounts: [Account]
    @Binding var selection: String?
    let loaded: Bool
    let searchPrompt: String
    /// The list's identifier (`aws.list`, `gcp.list`).
    let identifier: String
    let sectionTitle: (Account.Kind) -> String
    @ViewBuilder let row: (Account) -> Row
    @ViewBuilder let bar: () -> Bar
    @State private var search = ""

    private var visible: [Account] { accounts.filter { $0.matches(search) } }

    var body: some View {
        VStack(spacing: 0) {
            List(selection: $selection) {
                let shown = visible
                ForEach(Array(Account.Kind.allCases), id: \.self) { kind in
                    let members = shown.filter { $0.kind == kind }
                    if !members.isEmpty {
                        Section(sectionTitle(kind)) {
                            ForEach(members) { row($0).tag($0.id) }
                        }
                    }
                }
            }
            .listStyle(.sidebar)
            .themedScroll()
            .overlay {
                if loaded && !search.isEmpty && visible.isEmpty {
                    ContentUnavailableView.search(text: search)
                } else if !loaded {
                    ProgressView()
                }
            }
            .searchable(text: $search, placement: .sidebar, prompt: searchPrompt)
            .accessibilityIdentifier(identifier)
            HStack {
                bar()
                Spacer()
            }
            .padding(.horizontal, 10).frame(height: 29)
            .overlay(alignment: .top) { Divider() }
        }
    }
}

/// A row of a cloud account: its kind's tile, its name, a line about it and, at the end, a mark
/// when something needs the user.
struct CloudAccountRow: View {
    let symbol: String
    let title: String
    let subtitle: String
    var attention: String? = nil
    let identifier: String
    var body: some View {
        HStack(spacing: 8) {
            IconTile(symbol: symbol, size: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.uiBody).lineLimit(1).truncationMode(.middle)
                Text(subtitle).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            if let attention {
                Spacer(minLength: 4)
                Image(systemName: Symbols.warning).font(.uiCaption).foregroundStyle(Brand.warning)
                    .help(attention).accessibilityLabel(attention)
            }
        }
        .help(title)
        .accessibilityIdentifier(identifier)
    }
}

/// The top of a cloud account's card: its kind's tile, its name and kind, and a chip at the end
/// (the default profile, gcloud's active account).
struct CloudCardHeader<Chip: View>: View {
    let symbol: String
    let title: String
    let subtitle: String
    let titleIdentifier: String
    /// The name can be selected and is cut in the middle (an address); otherwise at the end.
    var selectable = false
    @ViewBuilder let chip: () -> Chip
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, size: 36)
            VStack(alignment: .leading, spacing: 2) {
                name.accessibilityIdentifier(titleIdentifier)
                Text(subtitle).font(.uiCallout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            chip()
        }
    }

    @ViewBuilder private var name: some View {
        let text = Text(title).font(.uiTitle3.weight(.semibold)).lineLimit(2)
        if selectable { text.truncationMode(.middle).textSelection(.enabled) } else { text }
    }
}
