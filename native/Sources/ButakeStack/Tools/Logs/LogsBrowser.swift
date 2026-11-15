import AppKit
import SwiftUI

/// Where a log comes from: the filter of Registros.
enum LogOrigin: String, CaseIterable, Identifiable {
    case web, php, services, projects, vault
    var id: String { rawValue }
    var title: String { L("logs.origin.\(rawValue)") }

    /// The origin of a source: a supervised process (`stack.caddy`, `stack.php-8-4`, `stack.mysql`,
    /// `<project>.<process>`, `share.<project>`) or the vault's access log.
    static func of(_ source: String) -> LogOrigin {
        if source == LogsBrowser.vaultSource { return .vault }
        if source == "stack.caddy" { return .web }
        if source.hasPrefix("stack.php-") { return .php }
        if source.hasPrefix("stack.") { return .services }
        return .projects
    }
}

/// The lines Registros shows by their severity, read from the line itself.
enum LogLevel: String, CaseIterable, Identifiable {
    case all, warnings, errors
    var id: String { rawValue }
    var title: String { L("logs.level.\(rawValue)") }

    private static let errorWords = ["error", "fatal", "panic", "critical", "crit]", "emerg", "alert]", "exception"]
    private static let warningWords = ["warn", "deprecated"]

    func admits(_ line: String) -> Bool {
        switch self {
        case .all: return true
        case .errors: return Self.isError(line)
        case .warnings: return Self.isError(line) || Self.warningWords.contains { line.localizedCaseInsensitiveContains($0) }
        }
    }
    private static func isError(_ line: String) -> Bool { errorWords.contains { line.localizedCaseInsensitiveContains($0) } }
}

/// A group of sources of the same origin, as the list shows it.
struct LogGroup: Identifiable, Equatable {
    let origin: LogOrigin
    let sources: [String]
    var id: String { origin.rawValue }
}

/// Registros: the origin and the source on screen, and how their lines are read (filter, level,
/// paused, cleared). The list in the content column and the page share it. A project's own log tab
/// keeps one of its own.
@MainActor @Observable final class LogsBrowser {
    static let shared = LogsBrowser()
    /// The vault's access log, a source like the supervised processes.
    nonisolated static let vaultSource = "vault.access"

    /// nil shows every origin.
    var origin: LogOrigin?
    var selection: String?
    /// Search of the list of sources.
    var search = ""
    /// Filter of the lines on screen.
    var filter = ""
    var level: LogLevel = .all
    /// The lines of a source frozen while it is paused.
    var paused: [String: [String]] = [:]
    /// The last line on screen when a source was cleared: what came before is hidden.
    var clearedAfter: [String: String] = [:]

    /// Shows a source with its origin as the filter.
    func show(_ source: String) {
        origin = .of(source)
        selection = source
        search = ""
    }

    /// `butakestack://tool/logs?source=<proceso>` or `?origin=<origen>`.
    func open(_ items: [URLQueryItem]?) {
        if let source = items?.first(where: { $0.name == "source" })?.value, !source.isEmpty {
            show(source)
        } else if let origin = items?.first(where: { $0.name == "origin" })?.value.flatMap(LogOrigin.init(rawValue:)) {
            self.origin = origin
            selection = nil
            search = ""
        }
    }

    /// The sources of each origin: the processes the supervisor runs, the vault's log while the vault
    /// exists, and the source asked for even when it is not running (its file may still be there).
    func groups(_ store: StackStore) -> [LogGroup] {
        var sources = (store.status?.processes ?? []).map(\.id)
        if store.pluginEnabled("vault"), VaultSession.shared.disk.exists { sources.append(Self.vaultSource) }
        if let selection, !sources.contains(selection) { sources.append(selection) }
        let query = search.trimmingCharacters(in: .whitespaces)
        return LogOrigin.allCases.compactMap { origin in
            guard self.origin == nil || self.origin == origin else { return nil }
            let matching = sources.filter { LogOrigin.of($0) == origin }
                .filter { query.isEmpty || title(store, $0).localizedCaseInsensitiveContains(query) || $0.localizedCaseInsensitiveContains(query) }
            return matching.isEmpty ? nil : LogGroup(origin: origin, sources: matching)
        }
    }

    func title(_ store: StackStore, _ source: String) -> String {
        source == Self.vaultSource ? L("plugin.vault.title") : store.processTitle(source)
    }

    /// The lines of a source as they are read: frozen while paused, after the last clear, filtered.
    func lines(_ store: StackStore, _ id: String) -> [String] {
        var all = paused[id] ?? store.logs[id] ?? []
        if let marker = clearedAfter[id], let index = all.lastIndex(of: marker) { all = Array(all[all.index(after: index)...]) }
        let text = filter
        return all.filter { (text.isEmpty || $0.localizedCaseInsensitiveContains(text)) && level.admits($0) }
    }

    func isPaused(_ id: String) -> Bool { paused[id] != nil }
    func setPaused(_ id: String, _ on: Bool, store: StackStore) { paused[id] = on ? (store.logs[id] ?? []) : nil }

    /// Hides the lines on screen; new ones keep coming. The log file is not touched.
    func clear(_ id: String, store: StackStore) {
        if let last = (paused[id] ?? store.logs[id])?.last { clearedAfter[id] = last }
        if paused[id] != nil { paused[id] = [] }
    }

    func copy(_ store: StackStore, _ id: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines(store, id).joined(separator: "\n"), forType: .string)
    }
}

extension StackStore {
    /// Registros filtered on a source: the one way to a log from a service, the web server, PHP-FPM
    /// or the vault (the sheet each of them had is gone).
    func showLogs(_ source: String) {
        LogsBrowser.shared.show(source)
        route = .tool("logs")
    }

    /// A readable name for a supervised process.
    func processTitle(_ id: String) -> String {
        if id == "stack.caddy" { return "Caddy" }
        if id.hasPrefix("stack.php-") { return "PHP-FPM " + id.dropFirst("stack.php-".count).replacingOccurrences(of: "-", with: ".") }
        if id.hasPrefix("stack.") { return Tech.of(String(id.dropFirst("stack.".count))).title }
        let parts = id.split(separator: ".", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return id }
        let site = projects.first { $0.id == parts[1] || $0.id == parts[0] }
        if parts[0] == "share" { return String(format: L("logs.share"), site?.title ?? parts[1]) }
        if parts[0] == "public" { return String(format: L("logs.public"), site?.title ?? parts[1]) }
        if id == "cloudflare.login" { return L("logs.cloudflareLogin") }
        return "\(projects.first { $0.id == parts[0] }?.title ?? parts[0]) · \(parts[1])"
    }
}

extension View {
    /// Opens Registros filtered on the process a row asks for, in the main window (also from Ajustes);
    /// the binding goes back to nil.
    func showsLogs(_ process: Binding<String?>, store: StackStore) -> some View {
        modifier(LogsLink(process: process, store: store))
    }
}

private struct LogsLink: ViewModifier {
    @Binding var process: String?
    let store: StackStore
    @Environment(\.openWindow) private var openWindow
    func body(content: Content) -> some View {
        content.onChange(of: process) { _, id in
            guard let id else { return }
            process = nil
            store.showLogs(id)
            openWindow(id: "main")
        }
    }
}
