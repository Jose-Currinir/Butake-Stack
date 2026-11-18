import AppKit
import SwiftUI

/// The columns of Inicio's project list. Fixed widths (a `List` row, not a `Table`: the folders
/// close and open, nest, and the columns that do not fit go away whole, never cut).
struct HomeColumns: Equatable {
    var address = true
    var branch = true

    static let spacing: CGFloat = 12
    /// What the page takes around the rows (page padding and the list's own insets).
    static let margins: CGFloat = 72
    static var name: CGFloat { TextScale.points(200) }
    static var addressWidth: CGFloat { TextScale.points(170) }
    static var branchWidth: CGFloat { TextScale.points(130) }
    static var stateWidth: CGFloat { TextScale.points(120) }
    static var actionWidth: CGFloat { TextScale.points(84) }

    /// Rama goes first, then Dirección, when the list is not wide enough for them.
    init(width: CGFloat) {
        let base = Self.name + Self.stateWidth + Self.actionWidth + 2 * Self.spacing + Self.margins
        let withAddress = base + Self.addressWidth + Self.spacing
        branch = width >= withAddress + Self.branchWidth + Self.spacing
        address = width >= withAddress
    }
    init() {}
}

/// Header of the project list: the same columns as its rows.
struct HomeColumnHeader: View {
    let columns: HomeColumns
    var body: some View {
        HStack(spacing: HomeColumns.spacing) {
            Text(L("home.col.project")).frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 34)
            if columns.address { Text(L("home.col.address")).frame(width: HomeColumns.addressWidth, alignment: .leading) }
            if columns.branch { Text(L("home.col.branch")).frame(width: HomeColumns.branchWidth, alignment: .leading) }
            Text(L("home.col.state")).frame(width: HomeColumns.stateWidth, alignment: .leading)
            Color.clear.frame(width: HomeColumns.actionWidth, height: 1)
        }
        .font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
        .accessibilityHidden(true)
    }
}

/// One project of Inicio: logo, name and kind, address, branch, state and the one action.
/// Double click or Return (the list's primary action) opens its page.
struct HomeProjectRow: View {
    @Bindable var store: StackStore
    let project: Project
    let columns: HomeColumns

    private var phase: ProcessPhase { project.enabled ? store.sitePhase(project) : .stopped }
    private var branch: String? { store.git[project.id].map { $0.branch.isEmpty ? L("git.detached") : $0.branch } }

    /// Kind and version in gray under the name; what a hidden column would say joins it.
    private var detail: String {
        if project.isMissing { return L("missing.title") }
        var parts = [project.tech.title]
        if !project.isServed && project.technology != nil { parts.append(L("kind.unserved")) }
        if let php = project.php { parts.append("PHP \(php)") }
        if !columns.address, project.url != nil { parts.append(project.domain) }
        if !columns.branch, let branch { parts.append(branch) }
        return parts.joined(separator: " · ")
    }

    private var stateText: String {
        if project.isMissing { return L("missing.title") }
        return project.enabled ? L("state.\(phase.rawValue)") : L("site.off")
    }
    private var stateColor: Color {
        switch phase {
        case .running: Brand.successText
        case .starting, .stopping: Brand.warningText
        case .crashed: Brand.dangerText
        case .stopped: .secondary
        }
    }

    var body: some View {
        HStack(spacing: HomeColumns.spacing) {
            HStack(spacing: 10) {
                TechLogo(tech: project.tech, size: TextScale.points(24)).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(project.title).font(.uiHeadline).lineLimit(1)
                    Text(detail).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                }
                // Something it needs (P-42): the first cause on hover, the rest on its page.
                if !project.isMissing, let first = store.attention[project.id]?.first {
                    Image(systemName: Symbols.warning).foregroundStyle(Brand.warningText).help(store.attentionText(first))
                        .accessibilityLabel(L("attention.title"))
                        .accessibilityIdentifier("home.site.attention.\(project.id)")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if columns.address {
                address.frame(width: HomeColumns.addressWidth, alignment: .leading)
            }
            if columns.branch {
                Text(branch ?? "").font(.uiCaption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    .frame(width: HomeColumns.branchWidth, alignment: .leading)
            }
            state.frame(width: HomeColumns.stateWidth, alignment: .leading)
            action.frame(width: HomeColumns.actionWidth, alignment: .trailing)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .accessibilityElement(children: .contain)
        .accessibilityLabel(project.title)
        .accessibilityValue(project.isServed ? stateText : "")
        .accessibilityIdentifier("home.site.\(project.id)")
    }

    @ViewBuilder private var address: some View {
        if let url = project.url {
            Button { NSWorkspace.shared.open(url) } label: { Text(project.domain).lineLimit(1).truncationMode(.middle) }
                .buttonStyle(.link).font(.uiCallout)
                .help(L("menu.openInBrowser"))
                .accessibilityIdentifier("home.site.address.\(project.id)")
        }
    }

    @ViewBuilder private var state: some View {
        if project.isMissing {
            HStack(spacing: 6) {
                Image(systemName: Symbols.missingFolder).foregroundStyle(Brand.warningText).accessibilityHidden(true)
                Text(L("missing.title")).font(.uiCallout).foregroundStyle(Brand.warningText).lineLimit(1)
            }
            .help(L("missing.title"))
            .accessibilityIdentifier("home.site.missing.\(project.id)")
        } else if project.isServed {
            HStack(spacing: 6) {
                StatusDot(color: phase.color, symbol: phase.markSymbol, label: stateText)
                Text(stateText).font(.uiCallout).foregroundStyle(stateColor).lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("home.site.state.\(project.id)")
        }
    }

    @ViewBuilder private var action: some View {
        if project.isServed && !project.isMissing {
            Button(project.enabled ? L("palette.stop") : L("palette.start")) {
                Task { await store.setSite(project, enabled: !project.enabled) }
            }
            .buttonStyle(.bordered).controlSize(.small)
            .help(String(format: L("site.powerFor"), project.title))
            .accessibilityIdentifier("home.site.toggle.\(project.id)")
        }
    }
}
