import SwiftUI

/// The frame every sheet shares: title (with its symbol and a line of detail), content, an
/// optional note, and the footer with Cancel on the left of the action. The sheet takes its
/// minimum and ideal size from `width` and `height`, never a fixed one.
struct SheetFrame<Content: View, Status: View>: View {
    let title: String
    let symbol: String?
    let detail: String?
    /// One line above the buttons; longer explanations go to `.help`.
    let note: String?
    let width: CGFloat
    let height: CGFloat?
    let actionTitle: String
    let actionSymbol: String?
    let actionID: String
    let canAct: Bool
    /// Identifier of Cancel; nil when the action is the only way out (a sheet that only shows).
    let cancelID: String?
    /// Cancel's title when it is not «Cancelar» (an assistant's «Más tarde»).
    let cancelTitle: String?
    /// Runs the action; true closes the sheet. The action is disabled while it runs.
    let action: () async -> Bool
    /// What Cancel does instead of closing (stopping an install), whether it can now, and why not.
    var onCancel: (() -> Void)?
    var cancelEnabled = true
    var cancelHelp = ""
    let content: Content
    /// Leading side of the footer: a reassurance, a counter.
    let status: Status
    @State private var running = false
    @Environment(\.dismiss) private var dismiss

    init(title: String, symbol: String? = nil, detail: String? = nil, note: String? = nil, width: CGFloat = 520, height: CGFloat? = nil,
         actionTitle: String, actionSymbol: String? = nil, actionID: String, canAct: Bool = true, cancelID: String? = nil,
         cancelTitle: String? = nil, action: @escaping () async -> Bool, @ViewBuilder content: () -> Content, @ViewBuilder status: () -> Status) {
        self.title = title; self.symbol = symbol; self.detail = detail; self.note = note; self.width = width; self.height = height
        self.actionTitle = actionTitle; self.actionSymbol = actionSymbol; self.actionID = actionID; self.canAct = canAct
        self.cancelID = cancelID; self.cancelTitle = cancelTitle; self.action = action; self.content = content(); self.status = status()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            content
            if let note {
                Text(note).font(.uiCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                status
                Spacer()
                if running { ProgressView().controlSize(.small) }
                if let cancelID {
                    Button(cancelTitle ?? L("common.cancel")) { if let onCancel { onCancel() } else { dismiss() } }
                        .keyboardShortcut(.cancelAction).disabled(!cancelEnabled).help(cancelHelp)
                        .accessibilityIdentifier(cancelID)
                }
                Button {
                    running = true
                    Task {
                        let close = await action()
                        running = false
                        if close { dismiss() }
                    }
                } label: {
                    if let actionSymbol { Label(actionTitle, systemImage: actionSymbol) } else { Text(actionTitle) }
                }
                .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                .disabled(!canAct || running)
                .accessibilityIdentifier(actionID)
            }
        }
        .padding(20)
        .frame(minWidth: width, idealWidth: width, minHeight: height, idealHeight: height)
    }

    /// Cancel runs `action` (when given) instead of closing; disabled with `help` when it can't now.
    func cancelling(_ action: (() -> Void)?, enabled: Bool = true, help: String = "") -> Self {
        var copy = self
        copy.onCancel = action
        copy.cancelEnabled = enabled
        copy.cancelHelp = help
        return copy
    }

    private var header: some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: 12) {
            if let symbol { IconTile(symbol: symbol, size: detail == nil ? 30 : 40) }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.uiTitle3.weight(.semibold)).frame(maxWidth: .infinity, alignment: .leading)
                if let detail {
                    Text(detail).font(.uiCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Spacer(minLength: 0)
        }
    }
}

extension SheetFrame where Status == EmptyView {
    init(title: String, symbol: String? = nil, detail: String? = nil, note: String? = nil, width: CGFloat = 520, height: CGFloat? = nil,
         actionTitle: String, actionSymbol: String? = nil, actionID: String, canAct: Bool = true, cancelID: String? = nil,
         action: @escaping () async -> Bool, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, detail: detail, note: note, width: width, height: height, actionTitle: actionTitle,
                  actionSymbol: actionSymbol, actionID: actionID, canAct: canAct, cancelID: cancelID, action: action,
                  content: content, status: { EmptyView() })
    }
}
