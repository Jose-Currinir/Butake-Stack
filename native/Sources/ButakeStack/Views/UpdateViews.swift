import SwiftUI

/// Sidebar footer: installed version, and a highlighted button when a newer release exists.
struct VersionBadge: View {
    let updates: UpdateService
    var body: some View {
        if updates.updateAvailable, let latest = updates.latest {
            Button { updates.showingSheet = true } label: {
                Label(String(format: L("updateAvailableShort"), latest.version), systemImage: "arrow.down.circle.fill")
                    .font(.ui(size: 11, weight: .semibold)).foregroundStyle(Brand.accent)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(Brand.accent.opacity(0.14), in: Capsule())
            }
            .buttonStyle(.plain).help(String(format: L("updateAvailableHelp"), latest.version, updates.current))
            .accessibilityIdentifier("sidebar.update")
            .transition(.scale.combined(with: .opacity))
        } else {
            Button { Task { await updates.check(userInitiated: true) } } label: {
                Text("v\(updates.current)").font(.ui(size: 11, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            }
            .buttonStyle(.plain).help(L("updateCheckNow")).accessibilityLabel("\(L("version")) \(updates.versionLabel). \(L("updateCheckNow"))")
            .accessibilityIdentifier("sidebar.version")
        }
    }
}

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
                    Text(title).font(.ui(size: 17, weight: .semibold))
                    Text(String(format: L("updateInstalled"), updates.current)).font(.uiCallout).foregroundStyle(.secondary)
                }
            }
            if updates.updateAvailable, let latest = updates.latest {
                ScrollView {
                    Text(notes(latest.notes)).font(.ui(size: 13)).lineSpacing(4).frame(maxWidth: .infinity, alignment: .leading)
                        .fixedSize(horizontal: false, vertical: true).textSelection(.enabled).padding(12)
                }
                .frame(minHeight: 160, maxHeight: 380).background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 10))
                Label(L("updateVerification"), systemImage: "checkmark.shield").font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if case .failed(let message) = updates.phase {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.uiCallout).foregroundStyle(Brand.warning).fixedSize(horizontal: false, vertical: true)
            }
            if busy {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(progressText).font(.uiCallout).foregroundStyle(.secondary) }
            }
            HStack {
                if let latest = updates.latest { Button(L("updateViewRelease")) { NSWorkspace.shared.open(latest.page) } }
                Spacer()
                Button(updates.updateAvailable ? L("updateLater") : L("close")) { dismiss() }.keyboardShortcut(.cancelAction).disabled(updates.phase == .installing)
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
        return (try? AttributedString(markdown: body, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(body)
    }
}

/// Settings › General › Updates.
struct UpdateSettingsSection: View {
    @AppStorage("autoUpdateCheck") private var automatic = true
    let updates = UpdateService.shared
    var body: some View {
        Section(L("updatesSection")) {
            Toggle(L("updateAutomatic"), isOn: $automatic)
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(L("version")) \(updates.versionLabel)").textSelection(.enabled)
                        .help(updates.build.isEmpty ? "" : String(format: L("buildNumber"), updates.build))
                    if let last = updates.lastCheck { Text(String(format: L("updateLastCheck"), last.formatted(date: .abbreviated, time: .shortened))).font(.uiCaption).foregroundStyle(.secondary) }
                }
                Spacer()
                Button(L("updateCheckNow")) { Task { await updates.check(userInitiated: true) } }
            }
        }
    }
}
