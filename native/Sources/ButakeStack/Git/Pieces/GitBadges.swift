import SwiftUI

extension GitChangeKind {
    /// Green and red only for what is added and removed; every color reads with AA contrast.
    @MainActor var color: Color {
        let palette = GitDiffPalette.current
        return switch self {
        case .added: Color(nsColor: palette.addition)
        case .modified: Color(nsColor: palette.modified)
        case .deleted: Color(nsColor: palette.deletion)
        case .moved: Color(nsColor: palette.moved)
        case .conflict: Color(nsColor: palette.warning)
        }
    }
}

/// «+12 −3» of a file or a folder; «Binario» when the file is not text.
struct GitStatsBadge: View {
    let stats: GitLineStats
    var body: some View {
        let palette = GitDiffPalette.current
        HStack(spacing: 4) {
            if stats.binary {
                Text(L("git.diff.binaryShort")).foregroundStyle(.secondary)
            } else {
                // No number transitions or tooltip: this badge sits in every row of long lists.
                if let additions = stats.additions, additions > 0 { Text("+\(additions)").foregroundStyle(Color(nsColor: palette.addition)) }
                if let deletions = stats.deletions, deletions > 0 { Text("−\(deletions)").foregroundStyle(Color(nsColor: palette.deletion)) }
            }
        }
        .font(.uiCaption.monospacedDigit().weight(.semibold))
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(stats.binary ? L("git.diff.binaryShort") : String(format: L("git.diff.linesChanged"), stats.additions ?? 0, stats.deletions ?? 0))
    }
}

/// «Nuevo», «Eliminado», «Movido»… as a chip, or only its symbol in compact rows.
struct GitChangeKindBadge: View {
    let kind: GitChangeKind
    var compact = false
    var body: some View {
        Group {
            if compact {
                Image(systemName: kind.symbol).foregroundStyle(kind.color).font(.uiCallout)
            } else {
                Chip(text: kind.title, symbol: kind.symbol, tint: kind.color)
            }
        }
        .help(kind.title)
        .accessibilityLabel(kind.title)
        .fixedSize()
    }
}
