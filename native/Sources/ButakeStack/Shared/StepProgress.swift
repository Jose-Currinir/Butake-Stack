import SwiftUI

/// One step of a long operation (creating a project, installing a utility or a version).
struct ProgressStep: Identifiable, Hashable {
    let id: String
    let title: String
}

/// The steps of a long operation as rows of a grouped form: done ones checked, the current one
/// with its progress (a bar when it can be measured, a spinner when not), the rest pending; the
/// header carries the overall bar. One component for every operation that shows steps.
struct StepListSection: View {
    let steps: [ProgressStep]
    /// Index of the current step; `steps.count` when all are done.
    let current: Int
    /// The current step stopped there (an error or a cancel): marked instead of spinning.
    var stopped = false
    /// Measured progress of the current step (a download) and what it says.
    var fraction: Double?
    var detail: String?
    /// Identifier prefix: `<área>.step`.
    let scope: String

    var body: some View {
        Section {
            ForEach(Array(steps.enumerated()), id: \.element.id) { index, step in
                LabeledContent {
                    if index < current {
                        Image(systemName: Symbols.success).foregroundStyle(Brand.success)
                    } else if index == current && stopped {
                        Image(systemName: Symbols.warning).foregroundStyle(Brand.warning)
                    } else if index == current, fraction == nil {
                        ProgressView().controlSize(.small)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(step.title).foregroundStyle(index > current ? .secondary : .primary)
                        if index == current && !stopped, let fraction {
                            ProgressView(value: fraction).accessibilityIdentifier("\(scope).\(step.id).bar")
                            if let detail {
                                Text(detail).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .accessibilityIdentifier("\(scope).\(step.id)")
            }
        } header: {
            HStack {
                Text(L("progress.steps"))
                Spacer()
                ProgressView(value: Double(min(current, steps.count)), total: Double(max(steps.count, 1))).frame(width: 140)
                    .animated(.smooth(duration: 0.5), value: current)
            }
        }
    }
}

/// The operation's output, folded under «Ver detalle»: closed, its last line; open, a console.
struct LogDisclosure: View {
    let lines: [String]
    @Binding var expanded: Bool
    let id: String

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            LogConsole(lines: lines).frame(height: 160)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("progress.detail"))
                if !expanded, let last = lines.last(where: { !$0.hasPrefix("$ ") && !$0.trimmingCharacters(in: .whitespaces).isEmpty }) {
                    Text(last).font(.uiSubheadline.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .accessibilityIdentifier(id)
    }
}

/// Lines of a command's output, following the last one.
struct LogConsole: View {
    let lines: [String]
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                        Text(line.isEmpty ? " " : line)
                            .font(.uiCaption.monospaced())
                            .foregroundStyle(line.hasPrefix("$ ") ? Brand.accent : .secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .id(index)
                    }
                }
                .padding(10)
                .textSelection(.enabled)
            }
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.05)))
            .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            .onAppear { proxy.scrollTo(lines.count - 1, anchor: .bottom) }
        }
    }
}

enum Elapsed {
    /// «m:ss» of a duration.
    static func clock(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
