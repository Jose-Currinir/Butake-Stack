import SwiftUI

/// Outcome of a check and the install flow: notes, verification steps and progress.
struct UpdateSheet: View {
    let updates: UpdateService
    @Environment(\.dismiss) private var dismiss
    var busy: Bool { [.checking, .downloading, .verifying, .installing].contains(updates.phase) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                BrandMark(size: 46)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title).font(.uiTitle2.weight(.semibold))
                    Text(String(format: L("updateInstalled"), updates.current)).font(.uiCallout).foregroundStyle(.secondary)
                }
            }
            if updates.updateAvailable, let latest = updates.latest {
                ScrollView {
                    Text(notes(latest.notes)).font(.uiBody).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled).padding(12)
                }
                .frame(minHeight: 160, maxHeight: 380).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))  // radius 10: outside the Radius scale, kept as it was
                Label(L("updateVerification"), systemImage: Symbols.verified).font(.uiCaption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            if case .failed(let message) = updates.phase {
                Label(message, systemImage: Symbols.warning).font(.uiCallout).foregroundStyle(Brand.warningText).frame(maxWidth: .infinity, alignment: .leading)
            }
            if busy {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(progressText).font(.uiCallout).foregroundStyle(.secondary) }
            }
            HStack {
                if let latest = updates.latest { Button(L("updateViewRelease")) { NSWorkspace.shared.open(latest.page) }.accessibilityIdentifier("update.viewRelease") }
                Spacer()
                Button(updates.updateAvailable ? L("updateLater") : L("common.close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(updates.phase == .installing)
                    .accessibilityIdentifier("update.later")
                if updates.updateAvailable {
                    // No default (Return) shortcut: installing quits the app and replaces it.
                    Button(L("updateInstall")) { Task { await updates.install() } }
                        .buttonStyle(.borderedProminent).disabled(busy).accessibilityIdentifier("update.install")
                }
            }
        }
        .padding(26).frame(width: 640)
    }
    private var title: String {
        switch updates.phase {
        case .checking: L("updateChecking")
        case .failed where updates.latest == nil: L("updateCheckFailed")
        default:
            if updates.updateAvailable, let latest = updates.latest { String(format: L("updateAvailableTitle"), latest.version) }
            else { L("updateUpToDate") }
        }
    }
    private var progressText: String {
        switch updates.phase {
        case .checking: L("updateChecking")
        case .downloading: L("updateDownloading")
        case .verifying: L("updateVerifying")
        case .installing: L("updateInstalling")
        default: ""
        }
    }
    /// Release notes without code blocks; headings become bold lines and list markers become bullets.
    private func notes(_ markdown: String) -> AttributedString {
        var lines: [String] = [], inCode = false
        // Only the "Cambios" section when present: the rest (download link, checksum) is for the web page.
        var source = markdown.components(separatedBy: .newlines)
        if let start = source.firstIndex(where: { $0.hasPrefix("#") && $0.localizedCaseInsensitiveContains("cambios") }) {
            let rest = source[(start + 1)...]
            source = Array(rest.prefix { !$0.hasPrefix("#") })
        }
        for raw in source {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") { inCode.toggle(); continue }
            if inCode { continue }
            if line.hasPrefix("#") { lines.append("**" + line.drop(while: { $0 == "#" || $0 == " " }) + "**"); continue }
            if line.hasPrefix("- ") || line.hasPrefix("* ") { lines.append("•  " + line.dropFirst(2)); continue }
            lines.append(line)
        }
        let text = lines.joined(separator: "\n").replacingOccurrences(of: "\n\n\n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.isEmpty ? L("updateNoNotes") : text
        return Self.withoutLinks(body)
    }
    /// Inline Markdown (bold, italics) without live links: the notes are written by whoever publishes the release, and a
    /// link with misleading text must not look trustworthy inside this window.
    nonisolated static func withoutLinks(_ markdown: String) -> AttributedString {
        guard var text = try? AttributedString(markdown: markdown, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return AttributedString(markdown) }
        for run in text.runs where run.link != nil { text[run.range].link = nil }
        return text
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    @AppStorage("autoUpdateCheck") private var automatic = true
    let updates = UpdateService.shared
    var body: some View {
        Section(L("updatesSection")) {
            Toggle(L("updateAutomatic"), isOn: $automatic).accessibilityIdentifier("update.automatic")
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(L("version")) \(updates.versionLabel)").textSelection(.enabled)
                        .help(updates.build.isEmpty ? "" : String(format: L("buildNumber"), updates.build))
                    if let last = updates.lastCheck { Text(String(format: L("updateLastCheck"), Format.shortDateTime(last))).font(.uiCaption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button { Task { await updates.check(userInitiated: true) } } label: { Label(L("updateCheckNow"), systemImage: Symbols.reload) }
                    .accessibilityIdentifier("settings.checkUpdates")
            }
        }
    }
}
