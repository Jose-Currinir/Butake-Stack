import SwiftUI

/// How the assistant of the session shown is doing, at the end of the tab bar: a short line with
/// what it reports (context, session of 5 hours, week) or just «Consumo», and a popover with the
/// detail and the assistant's own commands. Nothing here is computed by Stack.
struct AssistantUsageButton: View {
    @Bindable var session: TerminalSession
    let source: AssistantUsageSource
    @State private var shown = false

    var body: some View {
        let usage = session.usage
        let summary = usage?.summary ?? ""
        Button { shown.toggle() } label: {
            Label {
                Text(summary.isEmpty ? L("ssh.usage.title") : summary).monospacedDigit().lineLimit(1)
            } icon: {
                Image(systemName: Symbols.usage).foregroundStyle(AssistantUsageMeter.tint(usage?.peak ?? 0) ?? Color.secondary)
            }
            .font(.uiCallout)
        }
        .buttonStyle(.borderless)
        .help(L("ssh.usage.help"))
        .accessibilityIdentifier("ssh.usage.button")
        .popover(isPresented: $shown, arrowEdge: .bottom) {
            AssistantUsagePanel(session: session, source: source) { shown = false }
        }
    }
}

/// The popover: each value the assistant reported with its bar, then its commands.
struct AssistantUsagePanel: View {
    @Bindable var session: TerminalSession
    let source: AssistantUsageSource
    var close: () -> Void = {}

    private var program: String { session.kind.launch.map { L("tool.\($0.program)") } ?? "" }
    /// Why there is no number yet, said as it is.
    private var absence: String {
        if !source.reportsStatus { return String(format: L("ssh.usage.none.unsupported"), program) }
        if !session.running { return L("ssh.usage.none.ended") }
        return L(session.usageReported ? "ssh.usage.none.waiting" : "ssh.usage.none.ownStatusLine")
    }

    var body: some View {
        let usage = session.usage.flatMap { $0.isEmpty ? nil : $0 }
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(L("ssh.usage.title")).font(.uiHeadline)
                Spacer(minLength: 12)
                if let model = usage?.model { Text(model).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1) }
            }
            if let usage {
                if let context = usage.contextPercent { AssistantUsageMeter(title: L("ssh.usage.context"), percent: context, id: "context") }
                if let limit = usage.session { AssistantUsageMeter(title: L("ssh.usage.session"), percent: limit.percent, resets: limit.resets, id: "session") }
                if let limit = usage.week { AssistantUsageMeter(title: L("ssh.usage.week"), percent: limit.percent, resets: limit.resets, id: "week") }
                if usage.session == nil && usage.week == nil {
                    Text(L("ssh.usage.noLimits")).font(.uiCaption).foregroundStyle(.secondary)
                }
                if let cost = usage.costUSD {
                    LabeledContent(L("ssh.usage.cost")) { Text(cost.formatted(.currency(code: "USD").precision(.fractionLength(2)))).monospacedDigit() }
                        .font(.uiCallout).help(L("ssh.usage.costHelp")).accessibilityIdentifier("ssh.usage.cost")
                }
            } else {
                Text(absence).font(.uiCallout).foregroundStyle(.secondary).accessibilityIdentifier("ssh.usage.none")
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                ForEach(source.commands) { command in
                    Button { session.run(command: command.id); close() } label: {
                        Label(String(format: L(command.titleKey), command.id), systemImage: Symbols.terminal)
                    }
                    .buttonStyle(.borderless).disabled(!session.running)
                    .help(L("ssh.usage.commandHelp")).accessibilityIdentifier("ssh.usage.command.\(command.id.dropFirst())")
                }
            }
            .font(.uiCallout)
            Text(String(format: L("ssh.usage.footer"), program)).font(.uiCaption).foregroundStyle(.tertiary)
        }
        .padding(14).frame(width: 300)
        .scaledText()
        .accessibilityIdentifier("ssh.usage.panel")
    }
}

/// One reported percentage: its name, the number, a bar, and when it starts over.
struct AssistantUsageMeter: View {
    let title: String
    let percent: Double
    var resets: Date?
    let id: String

    /// Near the limit the bar warns; nil while there is room.
    static func tint(_ percent: Double) -> Color? { percent >= 90 ? Brand.danger : percent >= 75 ? Brand.warning : nil }
    /// «a las 15:40» today, else the day too.
    static func moment(_ date: Date, now: Date = .now, calendar: Calendar = .current) -> String {
        calendar.isDate(date, inSameDayAs: now) ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.wide).day().month(.abbreviated).hour().minute())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                Spacer(minLength: 8)
                Text(AssistantUsage.percent(percent)).monospacedDigit().foregroundStyle(.secondary)
            }
            .font(.uiCallout)
            ProgressView(value: max(0, min(100, percent)), total: 100).tint(Self.tint(percent) ?? Color.accentColor)
                .accessibilityLabel(title).accessibilityIdentifier("ssh.usage.meter.\(id)")
            if let resets, resets > .now {
                Text(String(format: L("ssh.usage.resets"), Self.moment(resets))).font(.uiCaption).foregroundStyle(.secondary)
            }
        }
    }
}
