import AppKit
import SwiftUI

/// What a diff has to show.
enum GitDiffContent: Equatable {
    /// A unified diff, or the plain content of a new file (shown with line numbers).
    case patch(String)
    /// A file whose content is not text.
    case binary
    /// An image before and after the change (nil on the side where it does not exist).
    case image(before: NSImage?, after: NSImage?)
    /// A diff the caller already knows is too large; `lines` when it knows how many.
    case tooLarge(lines: Int?)
    /// Nothing changed.
    case unchanged
    /// The diff could not be read (shown as a warning, never as «sin cambios»).
    case failed(GitFailure)
}

/// The diff of one file, with every state it can be in: the text with old and new numbers, changes
/// inside each line, search, selection and copy, «Preparar bloque» on every block; a binary file; an
/// image before and after; a diff too large with «Mostrar de todos modos»; no changes.
struct GitDiffView: View {
    let content: GitDiffContent
    /// File shown, for syntax colors and the image's name.
    var path: String?
    /// Text to find and mark in the diff.
    var search = ""
    /// «Preparar bloque»: the index of the block (`@@ … @@`, from 0). Without it there are no buttons.
    var onStageHunk: ((Int) -> Void)?
    /// «Mostrar de todos modos» of `.tooLarge`; for a `.patch` over the limit the view shows it itself.
    var onShowAnyway: (() -> Void)?

    /// A patch with more lines than this is not drawn until the user asks for it.
    static let largeLineLimit = 25_000
    /// … or this many UTF-8 bytes.
    static let largeByteLimit = 4_000_000

    @State private var shownAnyway: String?

    var body: some View {
        Group {
            switch content {
            case .patch(let text) where text.isEmpty:
                unchanged
            case .patch(let text):
                if shownAnyway != text, let lines = Self.oversize(text) {
                    tooLarge(lines: lines) { shownAnyway = text }
                } else {
                    GitDiffText(text: text, path: path, search: search, onStageHunk: onStageHunk)
                }
            case .binary:
                ContentUnavailableView {
                    Label(L("git.diff.binaryTitle"), systemImage: Symbols.binaryFile)
                } description: {
                    Text(L("git.diff.binaryDetail"))
                }
                .accessibilityIdentifier("git.diff.binary")
            case .image(let before, let after):
                GitImageDiff(before: before, after: after, path: path)
            case .tooLarge(let lines):
                tooLarge(lines: lines, action: onShowAnyway)
            case .unchanged:
                unchanged
            case .failed(let failure):
                Notice(.warning, failure.title, detail: failure.detail.isEmpty ? nil : failure.detail)
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .top)
                    .accessibilityIdentifier("git.diff.failed")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: GitDiffPalette.current.surface))
    }

    /// Lines of a patch over the limits, or nil when it can be drawn at once.
    static func oversize(_ text: String) -> Int? {
        let lines = GitUnifiedDiff.lineCount(text)
        return lines > largeLineLimit || text.utf8.count > largeByteLimit ? lines : nil
    }

    private var unchanged: some View {
        ContentUnavailableView {
            Label(L("git.diff.unchangedTitle"), systemImage: Symbols.noChanges)
        } description: {
            Text(L("git.diff.unchangedDetail"))
        }
        .accessibilityIdentifier("git.diff.unchanged")
    }

    private func tooLarge(lines: Int?, action: (() -> Void)?) -> some View {
        ContentUnavailableView {
            Label(L("git.diff.largeTitle"), systemImage: Symbols.largeDiff)
        } description: {
            Text(lines.map { String(format: L("git.diff.largeDetailLines"), $0.formatted()) } ?? L("git.diff.largeDetail"))
        } actions: {
            if let action {
                Button(action: action) { Label(L("git.diff.showAnyway"), systemImage: Symbols.reveal) }
                    .buttonStyle(.borderedProminent)
                    .help(L("git.diff.showAnywayHelp"))
                    .accessibilityIdentifier("git.diff.showAnyway")
            }
        }
        .accessibilityIdentifier("git.diff.tooLarge")
    }
}

/// An image before and after its change, side by side, each with its size in pixels.
private struct GitImageDiff: View {
    let before: NSImage?
    let after: NSImage?
    var path: String?

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            side(L("git.diff.before"), before, missing: L("git.diff.imageNew"), id: "before")
            side(L("git.diff.after"), after, missing: L("git.diff.imageDeleted"), id: "after")
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("git.diff.image")
    }

    private func side(_ title: String, _ image: NSImage?, missing: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(title).font(.uiHeadline)
                Spacer()
                if let image, let rep = image.representations.first {
                    Text(String(format: L("git.diff.imageSize"), rep.pixelsWide, rep.pixelsHigh)).font(.uiCaption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Group {
                if let image {
                    Image(nsImage: image).resizable().interpolation(.high).scaledToFit()
                        .accessibilityLabel(path.map { (($0 as NSString).lastPathComponent) + " · " + title } ?? title)
                } else {
                    ContentUnavailableView(missing, systemImage: Symbols.imageFile)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(10)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(nsColor: .separatorColor)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityIdentifier("git.diff.image.\(id)")
    }
}
