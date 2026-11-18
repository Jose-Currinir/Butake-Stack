import SwiftUI

/// A commit or a comparison as a page of cards, one per file: the header says what happened to the
/// file and stays pinned while its changes scroll under it; a click on it opens or closes the file.
///
/// Build the sections with `GitDiffSection.split(text)`; `collapsed` and `toggle` keep the closed
/// cards in the caller (so they survive a refresh).
struct GitDiffSectionsView: View {
    let sections: [GitDiffSection]
    let collapsed: Set<Int>
    let toggle: (Int) -> Void
    var search = ""
    /// «Preparar bloque» of a file's block: the section's file and the block's index in it.
    var onStageHunk: ((GitDiffFile, Int) -> Void)?
    /// Measured height of each open diff (reported by the AppKit view once laid out).
    @State private var heights: [Int: CGFloat] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(sections) { section in
                    if let file = section.file {
                        let open = section.expandable && !collapsed.contains(section.id)
                        Section {
                            if open {
                                GitDiffText(text: section.patch, path: file.path, search: search,
                                            onStageHunk: onStageHunk.map { stage in { hunk in stage(file, hunk) } },
                                            embedded: true) { height in if heights[section.id] != height { heights[section.id] = height } }
                                    .frame(height: heights[section.id] ?? Self.estimate(section.patch))
                                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8))
                                    .overlay { UnevenRoundedRectangle(bottomLeadingRadius: 8, bottomTrailingRadius: 8).strokeBorder(Color(nsColor: .separatorColor)) }
                                    .padding(.bottom, 12)
                            }
                        } header: {
                            GitDiffFileHeader(file: file, open: open, expandable: section.expandable) { toggle(section.id) }
                                .padding(.bottom, open ? 0 : 8)
                        }
                    } else if let note = section.note {
                        GitDiffNote(text: note).padding(.bottom, 14)
                    }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .accessibilityIdentifier("git.diff.sections")
    }

    /// Height before the first layout: about one row per line (the header lines are not shown).
    static func estimate(_ patch: String) -> CGFloat {
        CGFloat(max(1, patch.utf8.reduce(0) { $1 == 0x0A ? $0 + 1 : $0 } - 2)) * TextScale.points(18.5) + 12
    }
}

/// Header of a file card: disclosure arrow, file icon, name and folder, what happened to it and its counts.
private struct GitDiffFileHeader: View {
    let file: GitDiffFile
    let open: Bool
    var expandable = true
    let action: () -> Void

    private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(topLeadingRadius: 8, bottomLeadingRadius: open ? 0 : 8, bottomTrailingRadius: open ? 0 : 8, topTrailingRadius: 8)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: Symbols.disclosure).font(.uiCaption.weight(.bold)).foregroundStyle(.secondary)
                    .rotationEffect(.degrees(open ? 90 : 0)).frame(width: 12).opacity(expandable ? 1 : 0)
                    .animated(.snappy(duration: 0.2), value: open)
                FileTypeIcon(path: file.path, size: 17)
                Text((file.path as NSString).lastPathComponent).font(.uiCallout.weight(.semibold)).lineLimit(1)
                if case let folder = (file.path as NSString).deletingLastPathComponent, !folder.isEmpty {
                    Text(folder).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
                GitChangeKindBadge(kind: file.kind)
                if let original = file.originalPath {
                    Text(String(format: L("git.diff.movedFrom"), original)).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 8)
                GitStatsBadge(stats: file.binary ? GitLineStats() : GitLineStats(additions: file.additions, deletions: file.deletions))
            }
            .padding(.horizontal, 12)
            .frame(minHeight: 36)
            // Opaque: the header stays pinned over the changes that scroll under it.
            .background { shape.fill(Color(nsColor: GitDiffPalette.current.surface)).overlay(shape.fill(Color.primary.opacity(0.06))) }
            .overlay { shape.strokeBorder(Color(nsColor: .separatorColor)) }
        }
        .buttonStyle(HighlightButtonStyle())
        // A file that was only moved has nothing to open: its header reads normally but does nothing.
        .allowsHitTesting(expandable)
        .help(file.path)
        .accessibilityIdentifier("git.diff.file.\(file.path)")
        .accessibilityLabel("\(file.path), \(file.kind.title)")
        .accessibilityValue(expandable ? L(open ? "git.diff.expanded" : "git.diff.collapsed") : "")
    }
}

/// Commit header and message (or any text before the first file): subject, author line and body.
private struct GitDiffNote: View {
    let text: String
    var body: some View {
        let lines = text.split(separator: "\n", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        VStack(alignment: .leading, spacing: 4) {
            Text(lines[0]).font(.uiHeadline)
            if lines.count > 1, !lines[1].isEmpty { Text(lines[1]).font(.uiCaption).foregroundStyle(.secondary) }
            if lines.count > 2, case let body = lines[2].trimmingCharacters(in: .whitespacesAndNewlines), !body.isEmpty {
                Text(body).font(.uiCallout).padding(.top, 4)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 4)
    }
}
