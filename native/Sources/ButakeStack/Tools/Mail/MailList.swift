import AppKit
import SwiftUI

/// The inbox's selection and search, shared by the list (content column) and the message (detail).
@MainActor @Observable final class MailBrowser {
    static let shared = MailBrowser()
    var selection: MailSummary.ID?
    var search = ""
    var confirmingClear = false
    /// Edición › Buscar (⌘F): the list takes the keyboard in its search field.
    var searchRequests = 0

    func visible(_ messages: [MailSummary]) -> [MailSummary] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return messages }
        return messages.filter { [$0.from, $0.to, $0.subject].contains { $0.localizedCaseInsensitiveContains(query) } }
    }
}

/// Correo's column, like Mail: newest first, sender, time, subject and recipient.
struct MailList: View {
    @Bindable var store: StackStore
    @Bindable var browser = MailBrowser.shared
    @FocusState private var searchFocused: Bool
    var body: some View {
        let messages = browser.visible(store.mailMessages)
        List(selection: $browser.selection) {
            ForEach(messages) { mail in
                MailRow(mail: mail)
                    .tag(mail.id)
                    .contextMenu {
                        Button { Self.copy(mail.subject) } label: { Label(L("mail.copySubject"), systemImage: Symbols.copy) }
                            .disabled(mail.subject.isEmpty).accessibilityIdentifier("mail.list.menu.copySubject")
                        Button { Self.copy(mail.from) } label: { Label(L("mail.copySender"), systemImage: Symbols.copy) }
                            .disabled(mail.from.isEmpty).accessibilityIdentifier("mail.list.menu.copySender")
                        Divider()
                        Button(role: .destructive) { Task { await store.deleteMail(mail.id) } } label: { Label(L("common.delete"), systemImage: Symbols.delete) }
                            .accessibilityIdentifier("mail.list.menu.delete")
                    }
                    .accessibilityIdentifier("mail.row.\(mail.id)")
            }
        }
        .listStyle(.sidebar)
        .themedScroll()
        .overlay {
            if store.mailMessages.isEmpty { Text(L("mail.empty")).font(.uiCallout).foregroundStyle(.secondary) }
            else if messages.isEmpty { ContentUnavailableView.search(text: browser.search) }
        }
        .searchable(text: $browser.search, placement: .sidebar, prompt: L("mail.search"))
        .searchFocused($searchFocused)
        .onChange(of: browser.searchRequests) { searchFocused = true }
        .accessibilityIdentifier("mail.list")
    }
}

extension MailList {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct MailRow: View {
    let mail: MailSummary
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(mail.from.isEmpty ? L("mail.noSender") : mail.from).font(.uiBody.weight(.semibold)).lineLimit(1)
                Spacer(minLength: 4)
                Text(Date(timeIntervalSince1970: TimeInterval(mail.received)), format: .dateTime.hour().minute())
                    .font(.uiCaption).foregroundStyle(.secondary).monospacedDigit()
            }
            Text(mail.subject.isEmpty ? L("mail.noSubject") : mail.subject).font(.uiCallout).lineLimit(1)
            Text(mail.to).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        .padding(.vertical, 3)
    }
}
