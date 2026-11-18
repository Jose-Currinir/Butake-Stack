import Foundation

/// The utilities of the Utilidades page, by section, with the maker's site of each one. Stack
/// installs them from the maker's own source (engine/src/runtimes/utilities/ and its devtools/);
/// what each install checks is said by `toolSource.<id>` and where it goes by `utilities.place.<id>`.
enum UtilityCatalog {
    /// A section of the page and its row in the sidebar, with its tile: one symbol and one color per concept.
    struct Group: Identifiable {
        let id: String
        let tools: [String]
        let symbol: String
        let color: UInt32
        var title: String { L("utilities.section.\(id)") }
        var tech: Tech { Tech(id: "utilities.\(id)", title: title, symbol: symbol, color: color) }
    }

    static let groups: [Group] = [
        // AI in the purple of the IA work profile. The command lines never take the mark of a
        // tool: the cloud ones are not the accounts of Nube, and Git's is the terminal in Git's color,
        // not the Git tool's branch.
        Group(id: "ai", tools: ["codex", "claude-code", "claude-desktop", "chatgpt"], symbol: Symbols.ai, color: 0x7D5BED),
        Group(id: "cloud", tools: ["aws", "wrangler", "cloudflared"], symbol: Symbols.cloudCommands, color: 0x32ADE6),
        Group(id: "repos", tools: ["git", "gh"], symbol: Symbols.terminal, color: 0xF05032),
    ]
    static var all: [String] { groups.flatMap(\.tools) }
    static func group(_ id: String) -> Group? { groups.first { $0.id == id } }
    /// The page of Utilidades that holds this utility, or the first one.
    static func route(for tool: String? = nil) -> Route {
        .utilities(groups.first { group in tool.map(group.tools.contains) ?? false }?.id ?? groups[0].id)
    }
    /// Desktop apps, copied to `~/Applications`; the rest are command line utilities: they go in
    /// `~/.local/bin` and can be added to the terminal's PATH.
    static let apps: Set<String> = ["claude-desktop", "chatgpt"]
    static func isCommand(_ tool: String) -> Bool { !apps.contains(tool) }
    /// Utilities Stack builds from their source with Apple's compiler.
    static let needsAppleTools: Set<String> = ["git"]

    /// The maker's page of each new utility; gh, cloudflared and Wrangler keep theirs in `DevToolSource`.
    static let sites: [String: String] = [
        "codex": "https://developers.openai.com/codex/cli",
        "claude-code": "https://code.claude.com/docs",
        "claude-desktop": "https://claude.com/download",
        "aws": "https://aws.amazon.com/cli/",
        "chatgpt": "https://chatgpt.com/download/",
        "git": "https://git-scm.com/install/mac",
    ]
    static func site(_ tool: String) -> URL? { (sites[tool] ?? DevToolSource.pages[tool]).flatMap(URL.init(string:)) }
}
