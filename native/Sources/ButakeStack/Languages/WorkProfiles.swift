import AppKit
import SwiftUI

struct DevToolStatus: Decodable, Sendable, Hashable {
    let installed: Bool
    let version: String?
    var broken: Bool? = nil
    /// Where it was found (a program or an app).
    var path: String? = nil
    /// Stack installed it (its record lists that path): only then it updates or removes it.
    var managed: Bool? = nil
    /// Git from Apple's developer tools: shown as Apple's; Stack's own build can go before it.
    var apple: Bool? = nil
}

struct ToolUpdate: Decodable, Sendable, Hashable {
    let installed: String
    let latest: String
    let update: Bool
}
/// `devToolUpdates`: each tool against its newest version, and each Python line uv manages.
struct DevUpdates: Decodable, Sendable {
    /// Why the newest version of a tool could not be asked, when it is unknown.
    func unknownReason(_ tool: String) -> String? {
        guard tools[tool] == nil, let code = unavailable[tool] else { return nil }
        return EngineFailure(code: code).errorDescription
    }
    /// «Última versión conocida: X, consultada hace N h» when the version is from an earlier answer.
    func knownNote(_ tool: String, now: Date = Date()) -> String? {
        guard let when = known[tool], let version = tools[tool]?.latest else { return nil }
        let hours = max(1, Int(now.timeIntervalSince1970 - when) / 3600)
        return String(format: L("utilities.knownVersion"), version, hours)
    }
    var tools: [String: ToolUpdate] = [:]
    var python: [String: ToolUpdate] = [:]
    /// Sources that did not answer: the engine's error code ("source_rate_limited:12"…).
    var unavailable: [String: String] = [:]
    /// Versions known from an earlier answer: when they were asked (seconds since 1970).
    var known: [String: Double] = [:]
    init() {}
    private struct Key: CodingKey {
        var stringValue: String; var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        for key in container.allKeys {
            if key.stringValue == "python" { python = (try? container.decode([String: ToolUpdate].self, forKey: key)) ?? [:] }
            else if key.stringValue == "unavailable" { unavailable = (try? container.decode([String: String].self, forKey: key)) ?? [:] }
            else if key.stringValue == "known" { known = (try? container.decode([String: Double].self, forKey: key)) ?? [:] }
            else if let update = try? container.decode(ToolUpdate.self, forKey: key) { tools[key.stringValue] = update }
        }
    }
}
/// A supported Python line (endoflife.date).
struct PythonLine: Decodable, Sendable, Hashable, Identifiable {
    let version: String
    let latest: String?
    let eol: String?
    var id: String { version }
}

/// What someone works on, and what each kind of work needs on the Mac.
struct WorkProfile: Identifiable, Hashable {
    let id: String
    let logo: String
    let category: String
    let tools: [String]

    static let categories = ["web", "native", "crossplatform", "tools"]
    /// Profiles the user picked in Preparar (saved in the preferences).
    static var chosen: Set<String> { Set((UserDefaults.standard.string(forKey: "setup.profiles") ?? "").split(separator: ",").map(String.init)) }
    /// Profiles whose work runs on Node (installed in the setup's own step).
    static let needsNode: Set<String> = ["laravel", "web", "cloudflare", "react-native"]
    static let all: [WorkProfile] = [
        WorkProfile(id: "laravel", logo: "laravel", category: "web", tools: ["php", "node", "clt"]),
        WorkProfile(id: "web", logo: "astro", category: "web", tools: ["node", "clt"]),
        WorkProfile(id: "python", logo: "django", category: "web", tools: ["python", "clt"]),
        WorkProfile(id: "swift", logo: "swift", category: "native", tools: ["xcode", "clt", "swiftly"]),
        WorkProfile(id: "android", logo: "android", category: "native", tools: ["jdk", "android-studio", "android-sdk"]),
        WorkProfile(id: "rust", logo: "rust", category: "native", tools: ["rustup", "clt"]),
        WorkProfile(id: "kmp", logo: "kmp", category: "crossplatform", tools: ["jdk", "android-studio", "android-sdk", "xcode"]),
        WorkProfile(id: "react-native", logo: "react-native", category: "crossplatform", tools: ["node", "watchman", "cocoapods", "xcode", "android-studio", "jdk"]),
        WorkProfile(id: "github", logo: "github", category: "tools", tools: ["gh"]),
        WorkProfile(id: "cloudflare", logo: "emdash", category: "tools", tools: ["node", "wrangler", "cloudflared"]),
        WorkProfile(id: "ai", logo: "ai", category: "tools", tools: ["codex", "claude-code", "claude-desktop", "chatgpt"]),
        WorkProfile(id: "aws", logo: "aws", category: "tools", tools: ["aws"]),
    ]
}

/// Where each tool comes from: Stack installs its own (PHP, Node, Java, Apple's command line tools);
/// for the rest, the official page (automatic installers come next).
enum DevToolSource {
    static let pages: [String: String] = [
        "rustup": "https://rustup.rs",
        "uv": "https://docs.astral.sh/uv/getting-started/installation/",
        "xcode": "macappstore://apps.apple.com/app/id497799835",
        "android-studio": "https://developer.android.com/studio",
        "android-sdk": "https://developer.android.com/studio",
        "cloudflared": "https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/downloads/",
        "wrangler": "https://developers.cloudflare.com/workers/wrangler/install-and-update/",
        "gh": "https://cli.github.com",
        "cocoapods": "https://guides.cocoapods.org/using/getting-started.html",
        "watchman": "https://facebook.github.io/watchman/docs/install",
    ]
}

/// Tools Stack installs itself from their official source (verified), and what that means.
/// Python is a language of Stack: its versions are installed on its page, like PHP, Node and Java.
enum DevToolInstaller {
    static let automatic: Set<String> = ["rustup", "uv", "gh", "cloudflared", "wrangler", "android-sdk", "swiftly"]
    /// Utilities whose versions are managed on a language page; their row leads there.
    static let languages: [String: String] = ["php": "php", "node": "node", "jdk": "java", "python": "python"]
}

/// A command line utility (README §5 «Utilidad») and its state on this Mac, with the one action
/// that fits: install or update it here, open its official page, or go to its language's page.
struct ToolRow: View {
    @Bindable var store: StackStore
    let tool: String
    /// Inside a card the row brings its own margins; inside a grouped form the form gives them.
    var padded = true
    @State private var installing = false
    var status: DevToolStatus? {
        switch tool {
        case "clt": DevToolStatus(installed: store.appleTools, version: nil)
        case "python": store.pythonRuntimes.isEmpty ? nil : DevToolStatus(installed: true, version: store.pythonRuntimes.map(\.version).joined(separator: " · "))
        default: store.devTools[tool]
        }
    }
    /// Only what Stack installs itself is installed or updated here, through the confirmation that says
    /// where it comes from (toolSource.*); the rest opens its own installer or official page.
    var installsHere: Bool { DevToolInstaller.automatic.contains(tool) && !onUtilitiesPage }
    /// Utilities of the Utilidades page are installed, updated and removed only there: the row leads to it.
    var onUtilitiesPage: Bool { UtilityCatalog.all.contains(tool) }
    var update: ToolUpdate? {
        guard installsHere else { return nil }
        return store.devUpdates.tools[tool].flatMap { $0.update ? $0 : nil }
    }
    var busy: Bool { store.busy != nil }

    var body: some View {
        HStack(spacing: 10) {
            TechLogo(tech: .of(tool == "jdk" ? "java" : tool), size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("tool.\(tool)")).font(.uiCallout)
                Text(L("toolDetail.\(tool)")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 10)
            if let status, status.installed, status.broken != true {
                if let update {
                    Button { installing = true } label: { Label(String(format: L("tools.updateTo"), update.latest), systemImage: Symbols.update) }
                        .controlSize(.small).disabled(busy)
                        .help(String(format: L("tools.installedVersion"), update.installed))
                        .accessibilityIdentifier("tool.update.\(tool)")
                }
                Label(status.version ?? L("setup.ready"), systemImage: Symbols.success).font(.uiCaption.weight(.medium)).foregroundStyle(Brand.successText).lineLimit(1)
            } else {
                if status?.broken == true {
                    Label(L("tools.broken"), systemImage: Symbols.warning).font(.uiCaption.weight(.medium)).foregroundStyle(Brand.warningText)
                        .help(L("tools.brokenHelp"))
                }
                action
            }
        }
        .padding(.horizontal, padded ? 12 : 0).padding(.vertical, padded ? 8 : 0)
        // The same confirmation and step-by-step progress as on the Utilidades page.
        .sheet(isPresented: $installing) {
            UtilityInstallSheet(store: store, tool: tool, updating: status?.installed == true && status?.broken != true).themedSheet()
        }
        #if DEBUG
        .task { if installsHere, await QAHooks.opensUtilitySheet(tool) { installing = true } }
        #endif
    }

    @ViewBuilder private var action: some View {
        if onUtilitiesPage {
            Button { store.showSetup = false; store.route = UtilityCatalog.route(for: tool) } label: { Label(L("utilities.open"), systemImage: Symbols.forward) }
                .controlSize(.small)
                .accessibilityIdentifier("tool.utilities.\(tool)")
        } else if let language = DevToolInstaller.languages[tool] {
            // One place installs a language's versions: its page.
            Button { store.showSetup = false; store.route = .language(language) } label: { Label(L("tools.versions"), systemImage: Symbols.forward) }
                .controlSize(.small)
                .accessibilityIdentifier("tool.versions.\(tool)")
        } else if tool == "clt" {
            Button { store.installAppleTools() } label: { Label(L("common.install"), systemImage: Symbols.install) }
                .controlSize(.small).buttonStyle(.borderedProminent)
                .accessibilityIdentifier("tool.install.clt")
        } else if installsHere {
            Button { installing = true } label: { Label(L("utilities.install"), systemImage: Symbols.install) }
                .controlSize(.small).buttonStyle(.borderedProminent).disabled(busy)
                .accessibilityIdentifier("tool.install.\(tool)")
        } else if let page = DevToolSource.pages[tool], let url = URL(string: page) {
            Button { NSWorkspace.shared.open(url) } label: { Label(L("tools.official"), systemImage: Symbols.openInBrowser) }
                .controlSize(.small)
                .accessibilityIdentifier("tool.official.\(tool)")
        }
    }
}
