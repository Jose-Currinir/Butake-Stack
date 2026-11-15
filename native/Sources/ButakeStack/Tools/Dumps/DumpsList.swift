import SwiftUI

/// The dumps on screen: selection, search, and the list frozen while paused.
@MainActor @Observable final class DumpsBrowser {
    static let shared = DumpsBrowser()
    var selection: DumpEntry.ID?
    var search = ""
    /// The dumps kept on screen while paused; nil follows the receiver.
    var frozen: [DumpEntry]?

    func entries(_ store: StackStore) -> [DumpEntry] { frozen ?? store.dumps }

    func visible(_ store: StackStore) -> [DumpEntry] {
        let query = search.trimmingCharacters(in: .whitespaces)
        let all = entries(store)
        guard !query.isEmpty else { return all }
        return all.filter { dump in
            dump.lines.contains { $0.localizedCaseInsensitiveContains(query) }
                || (dump.source.map { $0.name.localizedCaseInsensitiveContains(query) || $0.file.localizedCaseInsensitiveContains(query) } ?? false)
                || (dump.origin?.localizedCaseInsensitiveContains(query) ?? false)
        }
    }
}

/// Dumps' column: newest first, where each came from and its first line.
struct DumpsList: View {
    @Bindable var store: StackStore
    @Bindable var browser = DumpsBrowser.shared
    var body: some View {
        let dumps = browser.visible(store)
        List(selection: $browser.selection) {
            ForEach(dumps) { dump in
                DumpRow(dump: dump).tag(dump.id).accessibilityIdentifier("dumps.row.\(dump.id)")
            }
        }
        .listStyle(.sidebar)
        .themedScroll()
        .overlay {
            if browser.entries(store).isEmpty { ContentUnavailableView(L("dumps.empty"), systemImage: Symbols.debugDump) }
            else if dumps.isEmpty { ContentUnavailableView.search(text: browser.search) }
        }
        .searchable(text: $browser.search, placement: .sidebar, prompt: L("dumps.search"))
        .accessibilityIdentifier("dumps.list")
    }
}

private struct DumpRow: View {
    let dump: DumpEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(dump.place ?? L("dumps.noSource")).font(.uiBody.weight(.semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                if let time = dump.time {
                    Text(Date(timeIntervalSince1970: time), format: .dateTime.hour().minute().second())
                        .font(.uiCaption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Text(dump.lines.first ?? "").font(.uiCaption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
        }
        .padding(.vertical, 3)
    }
}

extension DumpEntry {
    /// `file.php:12`, when the dump says where it was called.
    var place: String? {
        guard let source, !source.name.isEmpty else { return nil }
        return "\(source.name):\(source.line)"
    }
}
