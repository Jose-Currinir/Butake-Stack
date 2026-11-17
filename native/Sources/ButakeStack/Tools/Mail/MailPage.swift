import AppKit
import SwiftUI

/// Local mail, like Mail: the messages are in the window's content column (`MailList`) and this is
/// the one selected, read with native views (no web view). With nothing selected it shows what a
/// project needs to send its mail here; the same lines are in the toolbar.
struct MailPage: View {
    @Bindable var store: StackStore
    @Bindable var browser = MailBrowser.shared
    @State private var message: MailMessage?
    var port: Int { store.mailStatus?.port ?? store.config?.mail?.port ?? 2525 }
    var setupLines: [String] { ["MAIL_MAILER=smtp", "MAIL_HOST=127.0.0.1", "MAIL_PORT=\(port)", "MAIL_ENCRYPTION=null"] }

    var body: some View {
        VStack(spacing: 0) {
            if let owner = store.mailStatus?.busy { ReceiverConflict(port: port, owner: owner) }
            Group {
                if let message {
                    MailDetail(store: store, message: message).id(message.id)
                } else if browser.selection != nil {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if store.mailMessages.isEmpty {
                    ContentUnavailableView {
                        Label(L("mail.setupTitle"), systemImage: Symbols.message)
                    } description: {
                        Text(String(format: L("mail.setupDetail"), port))
                    } actions: {
                        ToolSetup(lines: setupLines, footer: L("mail.envHelp"), identifier: "mail.setup")
                    }
                } else {
                    ContentUnavailableView(L("mail.choose"), systemImage: Symbols.message)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            if #available(macOS 26, *) {
                // Apart from the window's own «+» (new project).
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Button(role: .destructive) { deleteSelected() } label: { Label(L("common.delete"), systemImage: Symbols.delete) }
                    .disabled(browser.selection == nil).help(L("mail.deleteHelp")).accessibilityIdentifier("mail.toolbar.delete")
                Button { browser.confirmingClear = true } label: { Label(L("mail.clear"), systemImage: Symbols.emptyInbox) }
                    .disabled(store.mailMessages.isEmpty).help(L("mail.clearHelp")).accessibilityIdentifier("mail.toolbar.clear")
                ToolSetupButton(lines: setupLines, footer: L("mail.envHelp"), identifier: "mail")
                ReceiverOptionsButton(tool: "mail", store: store)
            }
        }
        .task {
            while !Task.isCancelled {
                // With the daemon off or the app in the background, a poll would only fail or go unseen.
                guard store.daemonRunning, NSApp.isActive else {
                    try? await Task.sleep(for: .seconds(5))
                    continue
                }
                await store.loadMail()
                #if DEBUG
                if browser.selection == nil, QAHooks.mailSelectsFirst { browser.selection = store.mailMessages.first?.id }
                #endif
                try? await Task.sleep(for: .seconds(2.5))
            }
        }
        .task(id: browser.selection) {
            message = nil
            if let selected = browser.selection {
                let loaded = await store.mailMessage(selected)
                guard !Task.isCancelled, browser.selection == selected else { return }
                message = loaded
                // A message deleted elsewhere: nothing selected.
                if loaded == nil { browser.selection = nil }
            }
        }
        .confirmationDialog(L("mail.clearConfirm"), isPresented: $browser.confirmingClear) {
            Button(L("mail.clearAction"), role: .destructive) { Task { await store.deleteMail(nil); browser.selection = nil } }
            Button(L("common.cancel"), role: .cancel) {}
        } message: { Text(L("mail.clearDetail")) }
    }

    private func deleteSelected() {
        guard let id = browser.selection else { return }
        Task { await store.deleteMail(id); browser.selection = nil }
    }
}

/// A message: subject, who sent it to whom and when, its attachments, and its body as text, HTML
/// source, headers or the whole source.
private struct MailDetail: View {
    @Bindable var store: StackStore
    let message: MailMessage
    enum Mode: String, CaseIterable, Identifiable { case text, html, headers, source; var id: String { rawValue } }
    @State private var mode: Mode = .html
    var modes: [Mode] { Mode.allCases.filter { ($0 != .html || message.html != nil) && ($0 != .text || message.text != nil) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text(message.subject.isEmpty ? L("mail.noSubject") : message.subject).font(.uiTitle2.weight(.semibold))
                    .textSelection(.enabled)
                    .accessibilityIdentifier("mail.subject")
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                    field(L("mail.from"), message.from)
                    field(L("mail.to"), message.to)
                    if !message.cc.isEmpty { field(L("mail.cc"), message.cc) }
                    field(L("mail.date"), Format.shortDateTime(Date(timeIntervalSince1970: TimeInterval(message.received))))
                }
                if !message.attachments.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(message.attachments) { attachment in
                                Button { Task { await store.saveAttachment(message, attachment) } } label: {
                                    Label("\(attachment.name) · \(Format.fileSizeText(Int64(attachment.size)))", systemImage: Symbols.attachment)
                                }
                                .buttonStyle(.bordered).help(L("mail.saveAttachment")).accessibilityIdentifier("mail.attachment.\(attachment.index)")
                            }
                        }
                    }
                }
                Picker(L("mail.view"), selection: $mode) {
                    ForEach(modes) { Text(L("mail.mode.\($0.rawValue)")).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().padding(.top, 4).accessibilityIdentifier("mail.mode")
            }
            .padding(16)
            Divider()
            ScrollView {
                Text(content(mode)).font(mode == .text ? .uiBody : .uiCallout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .accessibilityIdentifier("mail.body")
        }
        .onAppear {
            mode = modes.first ?? .source
            #if DEBUG
            if let qa = QAHooks.mailMode, let wanted = Mode(rawValue: qa), modes.contains(wanted) { mode = wanted }
            #endif
        }
    }

    private func content(_ mode: Mode) -> String {
        switch mode {
        case .html: message.html ?? ""
        case .text: message.text ?? ""
        case .headers: message.headers.map { $0.joined(separator: ": ") }.joined(separator: "\n")
        case .source: message.source
        }
    }

    @ViewBuilder private func field(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).font(.uiCallout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
            Text(value).font(.uiCallout).textSelection(.enabled).lineLimit(2)
        }
    }
}
