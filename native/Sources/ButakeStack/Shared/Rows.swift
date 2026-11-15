import AppKit
import SwiftUI

/// A site that uses something (an engine, a language): its own logo and name, then a detail.
struct ProjectLinkRow: View {
    let project: Project
    var detail: String = ""
    let go: () -> Void
    var body: some View {
        Button(action: go) {
            HStack(spacing: 10) {
                TechLogo(tech: project.tech, size: 24)
                Text(project.title)
                Spacer()
                Text(detail).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: Symbols.forward).font(.uiCaption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightButtonStyle())
    }
}

/// A technology the site uses; clicking goes to its page.
struct TechRow: View {
    let tech: Tech
    let value: String
    let go: () -> Void
    var body: some View {
        Button(action: go) {
            HStack(spacing: 10) {
                TechLogo(tech: tech, size: 24)
                Text(tech.title)
                Spacer()
                Text(value).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: Symbols.forward).font(.uiCaption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HighlightButtonStyle())
    }
}

/// A label and its value, the one row for read-only data. With a symbol the label leads and the
/// value is secondary; without one the label is secondary and the value leads.
struct InfoRow: View {
    let title: String
    let value: String
    var symbol: String?
    /// Code, paths, keys, fingerprints.
    var mono = false
    /// The value is a state: green with a check when true, orange with a warning when false.
    var state: Bool?
    var lines = 1
    /// Identifier of a copy button for the value; without it there is no button.
    var copyID: String?
    /// The value opens this address (a project's local address), with its identifier.
    var link: URL?
    var linkID: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            if let symbol {
                Label(title, systemImage: symbol).font(.uiBody)
            } else {
                // A link row reads like the form rows around it: its title in the primary color.
                Text(title).font(.uiBody).foregroundStyle(link == nil ? .secondary : .primary).fixedSize()
            }
            Spacer(minLength: 8)
            if let state {
                Label(value, systemImage: state ? Symbols.success : Symbols.warning)
                    .foregroundStyle(state ? Brand.success : Brand.warning)
            } else if let link {
                Link(value, destination: link)
                    .lineLimit(1).truncationMode(.middle)
                    .help(L("menu.openInBrowser"))
                    .accessibilityIdentifier(linkID ?? "")
            } else {
                Text(value)
                    .font(mono ? .uiSubheadline.monospaced() : .uiBody)
                    .foregroundStyle(symbol == nil ? .primary : .secondary)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(lines).truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(value)
            }
            if let copyID {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(value, forType: .string)
                } label: { Label(L("common.copy"), systemImage: Symbols.copy).labelStyle(.iconOnly) }
                    .buttonStyle(.borderless).help(L("common.copy")).accessibilityIdentifier(copyID)
            }
        }
    }
}

/// A row of a grouped form led by a logo with a name and a line under it, its controls at the end,
/// both centered on the row (LabeledContent aligns them on the first line of text).
struct LogoRow<Content: View, Leading: View>: View {
    @ViewBuilder let content: Content
    @ViewBuilder let label: Leading
    var body: some View {
        HStack(spacing: 10) {
            label
            Spacer(minLength: 8)
            content
        }
    }
}

extension View {
    /// A text field of a grouped form: the row's title on the left and the field, with its border and
    /// its text from the left, filling the rest (a grouped form would draw it borderless and aligned
    /// to the right).
    func formField(_ title: String) -> some View {
        LabeledContent(title) {
            labelsHidden().textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
        }
    }
}
