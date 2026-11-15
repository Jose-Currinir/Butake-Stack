import SwiftUI

/// The toolbar's «Opciones…» of Correo and Dumps: the receiver's port and, for mail, how many days
/// and how many messages it keeps. Saved with `setMail` / `setDumps`; the daemon reloads it.
struct ReceiverOptionsButton: View {
    /// `mail` or `dumps`.
    let tool: String
    @Bindable var store: StackStore
    @State private var showing = false
    var body: some View {
        Button { showing = true } label: { Label(L("receiver.optionsEllipsis"), systemImage: Symbols.settings) }
            .help(L("receiver.optionsHelp"))
            .accessibilityIdentifier("\(tool).toolbar.options")
            .sheet(isPresented: $showing) { ReceiverOptionsSheet(tool: tool, store: store).themedSheet() }
            #if DEBUG
            .task { if ToolsQA.receiverOptions == tool { showing = true } }
            #endif
    }
}

/// The sheet; it starts from what `stack.json` says.
struct ReceiverOptionsSheet: View {
    let tool: String
    @Bindable var store: StackStore
    @State private var port: Int
    @State private var days: Int
    @State private var messages: Int

    init(tool: String, store: StackStore) {
        self.tool = tool
        self.store = store
        let server = tool == "mail" ? store.config?.mail : store.config?.dumps
        _port = State(initialValue: server?.port ?? ReceiverOptions.defaultPort(tool))
        _days = State(initialValue: server?.retentionDays ?? ReceiverOptions.defaultDays)
        _messages = State(initialValue: server?.maxMessages ?? ReceiverOptions.defaultMessages)
    }

    var body: some View {
        SheetFrame(title: L(tool == "mail" ? "receiver.mailTitle" : "receiver.dumpsTitle"), symbol: Symbols.settings,
                   note: L(ReceiverOptions.valid(port: port) ? "receiver.note" : "receiver.invalidPort"), width: 440,
                   actionTitle: L("common.save"), actionID: "\(tool).options.save",
                   canAct: ReceiverOptions.valid(port: port), cancelID: "\(tool).options.cancel") {
            await store.setReceiver(tool, port: port,
                                    retentionDays: tool == "mail" ? days : nil,
                                    maxMessages: tool == "mail" ? messages : nil)
        } content: {
            Form {
                Section {
                    TextField(L("receiver.port"), value: $port, format: .number.grouping(.never))
                        .accessibilityIdentifier("\(tool).options.port")
                    if tool == "mail" {
                        LabeledContent(L("receiver.retention")) {
                            Stepper(value: $days, in: ReceiverOptions.days) {
                                Text(String(format: L("receiver.retentionDays"), days)).monospacedDigit()
                            }
                            .accessibilityIdentifier("mail.options.days")
                        }
                        LabeledContent(L("receiver.maxMessages")) {
                            Stepper(value: $messages, in: ReceiverOptions.messages, step: 100) {
                                Text(verbatim: "\(messages)").monospacedDigit()
                            }
                            .accessibilityIdentifier("mail.options.messages")
                        }
                    }
                }
            }
            .formStyle(.grouped).themedScroll()
            .frame(minHeight: tool == "mail" ? 150 : 70)
        }
    }
}

/// The limits the engine accepts (`StackConfig::validate`).
enum ReceiverOptions {
    static let days = 1...365
    static let messages = 100...10_000
    static let defaultDays = 7
    static let defaultMessages = 500
    static func defaultPort(_ tool: String) -> Int { tool == "mail" ? 2525 : 9912 }
    static func valid(port: Int) -> Bool { (1024...65535).contains(port) }
}
