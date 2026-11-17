import SwiftUI

/// A message inside a page or a sheet: what happened or what needs doing, with its actions on
/// the trailing side. The style sets the symbol and the tint.
struct Notice<Actions: View>: View {
    enum Style { case info, progress, success, warning, error }

    let style: Style
    let title: String
    var detail: String?
    /// Replaces the style's symbol when the notice is about something specific (a branch, a folder).
    var symbol: String?
    /// Fraction done of a `.progress` notice; nil while it can't be measured.
    var value: Double?
    @ViewBuilder var actions: Actions

    private var tint: Color {
        switch style {
        case .info, .progress: Brand.info
        case .success: Brand.success
        case .warning: Brand.warning
        case .error: Brand.danger
        }
    }

    private var defaultSymbol: String {
        switch style {
        case .info, .progress: "info.circle"
        case .success: Symbols.success
        case .warning: Symbols.warning
        case .error: Symbols.error
        }
    }

    var body: some View {
        HStack(alignment: detail == nil ? .center : .top, spacing: 10) {
            Group {
                if style == .progress {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: symbol ?? defaultSymbol).foregroundStyle(tint).imageScale(.large)
                }
            }
            .accessibilityHidden(true)
            NoticeLayout(minText: TextScale.points(180), spacing: 8, centered: detail == nil) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(detail == nil ? .uiCallout.weight(.medium) : .uiHeadline)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let value {
                        ProgressView(value: value).frame(maxWidth: 260)
                    }
                    if let detail {
                        Text(detail).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .textSelection(.enabled)
                HStack(spacing: 8) { actions }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(tint.opacity(0.3)))
    }
}

extension Notice where Actions == EmptyView {
    init(_ style: Style, _ title: String, detail: String? = nil, symbol: String? = nil, value: Double? = nil) {
        self.init(style: style, title: title, detail: detail, symbol: symbol, value: value, actions: { EmptyView() })
    }
}

extension Notice {
    init(_ style: Style, _ title: String, detail: String? = nil, symbol: String? = nil, value: Double? = nil,
         @ViewBuilder actions: () -> Actions) {
        self.init(style: style, title: title, detail: detail, symbol: symbol, value: value, actions: actions)
    }
}

/// The text of a notice and its actions: side by side while the text keeps `minText` points, with
/// each button's whole title; when they don't fit (a narrow window, larger text), the actions go
/// under the text instead of being cut.
private struct NoticeLayout: Layout {
    let minText: CGFloat
    let spacing: CGFloat
    let centered: Bool

    private func sideBySide(_ width: CGFloat, _ actions: CGSize) -> Bool {
        actions.width == 0 || width - actions.width - spacing >= minText
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard subviews.count == 2 else { return .zero }
        let actions = subviews[1].sizeThatFits(.unspecified)
        let width = proposal.width ?? subviews[0].sizeThatFits(.unspecified).width + spacing + actions.width
        if sideBySide(width, actions) {
            // A notice without actions is always side by side: it too is measured at `minText` at least (P-15).
            let text = subviews[0].sizeThatFits(ProposedViewSize(width: max(minText, width - actions.width - (actions.width > 0 ? spacing : 0)), height: nil))
            return CGSize(width: width, height: max(text.height, actions.height))
        }
        // Never measured narrower than `minText`: asked for its smallest size (width 0, as the window
        // does to find its minimum), the text would wrap to a letter per line and report a height
        // taller than the window, which then starts its columns under the title bar (P-15).
        let text = subviews[0].sizeThatFits(ProposedViewSize(width: max(width, minText), height: nil))
        return CGSize(width: width, height: text.height + spacing + actions.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard subviews.count == 2 else { return }
        let actions = subviews[1].sizeThatFits(.unspecified)
        if sideBySide(bounds.width, actions) {
            let textWidth = max(0, bounds.width - actions.width - (actions.width > 0 ? spacing : 0))
            let text = subviews[0].sizeThatFits(ProposedViewSize(width: textWidth, height: nil))
            let height = max(text.height, actions.height)
            subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.minY + (centered ? (height - text.height) / 2 : 0)),
                              proposal: ProposedViewSize(width: textWidth, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.maxX - actions.width, y: bounds.minY + (centered ? (height - actions.height) / 2 : 0)),
                              proposal: ProposedViewSize(actions))
        } else {
            let text = subviews[0].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            subviews[0].place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.minY + text.height + spacing), proposal: ProposedViewSize(actions))
        }
    }
}
