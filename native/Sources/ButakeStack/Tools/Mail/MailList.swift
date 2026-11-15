import SwiftUI

/// The inbox's selection and search, shared by the list (content column) and the message (detail).
@MainActor @Observable final class MailBrowser {
    static let shared = MailBrowser()
    var selection: MailSummary.ID?
    var search = ""
    var confirmingClear = false

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
    var body: some View {
        let messages = browser.visible(store.mailMessages)
        List(selection: $browser.selection) {
            ForEach(messages) { mail in
                MailRow(mail: mail)
                    .tag(mail.id)
                    .contextMenu {
                        Button(role: .destructive) { Task { await store.deleteMail(mail.id) } } label: { Label(L("common.delete"), systemImage: Symbols.delete) }
                            .accessibilityIdentifier("mail.list.menu.delete")
                    }
                    .accessibilityIdentifier("mail.row.\(mail.id)")
            }
        }
        .listStyle(.sidebar)
        .themedScroll()
        .overlay {
            if store.mailMessages.isEmpty { ContentUnavailableView(L("mail.empty"), systemImage: Symbols.message) }
            else if messages.isEmpty { ContentUnavailableView.search(text: browser.search) }
        }
        .searchable(text: $browser.search, placement: .sidebar, prompt: L("mail.search"))
        .accessibilityIdentifier("mail.list")
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
