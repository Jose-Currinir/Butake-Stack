import AppKit
import SwiftUI

struct DevToolStatus: Decodable, Sendable, Hashable {
    let installed: Bool
    let version: String?
    var broken: Bool? = nil
}

/// Any JSON value, when only success matters.
struct JSONAny: Decodable, Sendable { init(from decoder: Decoder) throws {} }

struct ToolUpdate: Decodable, Sendable, Hashable {
    let installed: String
    let latest: String
    let update: Bool
}
/// `devToolUpdates`: each tool against its newest version, and each Python line uv manages.
struct DevUpdates: Decodable, Sendable {
    var tools: [String: ToolUpdate] = [:]
    var python: [String: ToolUpdate] = [:]
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
    static let all: [WorkProfile] = [
        WorkProfile(id: "laravel", logo: "laravel", category: "web", tools: ["php", "node", "clt"]),
        WorkProfile(id: "web", logo: "astro", category: "web", tools: ["node", "clt"]),
        WorkProfile(id: "python", logo: "django", category: "web", tools: ["uv", "python", "clt"]),
        WorkProfile(id: "swift", logo: "swift", category: "native", tools: ["xcode", "clt"]),
        WorkProfile(id: "android", logo: "android", category: "native", tools: ["jdk", "android-studio", "android-sdk"]),
        WorkProfile(id: "rust", logo: "rust", category: "native", tools: ["rustup", "clt"]),
        WorkProfile(id: "kmp", logo: "kmp", category: "crossplatform", tools: ["jdk", "android-studio", "android-sdk", "xcode"]),
        WorkProfile(id: "react-native", logo: "react-native", category: "crossplatform", tools: ["node", "watchman", "cocoapods", "xcode", "android-studio", "jdk"]),
        WorkProfile(id: "github", logo: "github", category: "tools", tools: ["gh"]),
        WorkProfile(id: "cloudflare", logo: "emdash", category: "tools", tools: ["node", "wrangler", "cloudflared"]),
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

/// "¿Con qué trabajas?": pick profiles, see what they need and its state on this Mac.
struct WorkProfilesSection: View {
    @Bindable var store: StackStore
    @AppStorage("setup.profiles") private var profilesRaw = ""
    var chosen: Set<String> { Set(profilesRaw.split(separator: ",").map(String.init)) }
    var tools: [String] {
        var seen = Set<String>()
        return WorkProfile.all.filter { chosen.contains($0.id) }.flatMap(\.tools).filter { seen.insert($0).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L("profiles.question")).font(.ui(size: 13, weight: .semibold))
            Text(L("profiles.hint")).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            // By category, each a row of its own: web, native, cross-platform, tools.
            VStack(alignment: .leading, spacing: 12) {
                ForEach(WorkProfile.categories, id: \.self) { category in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(L("category.work.\(category)")).font(.ui(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 4), spacing: 8) {
                            ForEach(WorkProfile.all.filter { $0.category == category }) { profile in
                                ProfileChip(profile: profile, selected: chosen.contains(profile.id)) { toggle(profile.id) }
                            }
                        }
                    }
                }
            }
            if !tools.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(tools.enumerated()), id: \.element) { index, tool in
                        if index > 0 { Divider().padding(.leading, 44) }
                        ToolRow(store: store, tool: tool)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.primary.opacity(0.035)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.25), value: tools)
        .task { await store.refreshDevTools() }
    }

    func toggle(_ id: String) {
        var set = chosen
        if set.contains(id) { set.remove(id) } else { set.insert(id) }
        profilesRaw = set.sorted().joined(separator: ",")
    }
}

private struct ProfileChip: View {
    let profile: WorkProfile
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                TechLogo(tech: .of(profile.logo), size: 26).saturation(selected ? 1 : 0.5)
                Text(L("profile.\(profile.id)")).font(.uiCaption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity).padding(.vertical, 10)
            .foregroundStyle(selected ? Brand.accent : .secondary)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(selected ? Brand.accent.opacity(0.12) : Color.primary.opacity(hovering ? 0.07 : 0.04)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(selected ? Brand.accent : .clear, lineWidth: 1.5))
            .overlay(alignment: .topTrailing) {
                if selected { Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Brand.accent).padding(5).transition(.scale.combined(with: .opacity)) }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.18), value: selected)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("profile.\(profile.id)")
    }
}

/// Tools Stack installs itself from their official source (verified), and what that means.
enum DevToolInstaller {
    static let automatic: Set<String> = ["rustup", "uv", "python", "gh", "cloudflared", "wrangler", "android-sdk"]
}

private struct ToolRow: View {
    @Bindable var store: StackStore
    let tool: String
    @State private var confirming = false
    @State private var pythonVersion = ""
    var status: DevToolStatus? {
        switch tool {
        case "clt": DevToolStatus(installed: store.appleTools, version: nil)
        case "python": store.devUpdates.python.isEmpty ? nil : DevToolStatus(installed: true, version: store.devUpdates.python.keys.sorted { $0.compare($1, options: .numeric) == .orderedDescending }.joined(separator: " · "))
        default: store.devTools[tool]
        }
    }
    var update: ToolUpdate? {
        if tool == "python" { return store.devUpdates.python.values.first { $0.update } }
        return store.devUpdates.tools[tool].flatMap { $0.update ? $0 : nil }
    }
    var busy: Bool { store.busy != nil }

    var body: some View {
        HStack(spacing: 10) {
            TechLogo(tech: .of(tool == "jdk" ? "java" : tool), size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("tool.\(tool)")).font(.uiCallout)
                Text(detail).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 10)
            if tool == "python" {
                pythonControls
            } else if let status, status.installed, status.broken != true {
                if let update {
                    Button { confirming = true } label: { Label(String(format: L("tools.updateTo"), update.latest), systemImage: "arrow.down.circle") }
                        .controlSize(.small).buttonStyle(.borderedProminent).disabled(busy)
                        .help(String(format: L("tools.installedVersion"), update.installed))
                }
                Label(status.version ?? L("setup.ready"), systemImage: "checkmark.circle.fill").font(.uiCaption.weight(.medium)).foregroundStyle(Brand.success).lineLimit(1)
            } else {
                if status?.broken == true {
                    Label(L("tools.broken"), systemImage: "exclamationmark.triangle.fill").font(.uiCaption.weight(.medium)).foregroundStyle(Brand.warning)
                        .help(L("tools.brokenHelp"))
                }
                action
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .confirmationDialog(confirmTitle, isPresented: $confirming) {
            if tool == "android-sdk" {
                Button(L("tools.acceptAndInstall")) { Task { await store.installDevTool(tool, acceptLicenses: true) } }
            } else if tool == "python" {
                Button(L("setup.install")) { Task { await store.installDevTool(tool, version: chosenPython) } }
            } else {
                Button(L("tools.installWithPath")) { Task { await store.installDevTool(tool, shellPath: true) } }
                Button(L("tools.installOnly")) { Task { await store.installDevTool(tool, shellPath: false) } }
            }
        } message: {
            Text(L("toolSource.\(tool)") + "\n\n" + L(tool == "android-sdk" ? "tools.licenses" : (tool == "python" ? "tools.pythonWhere" : "tools.where")))
        }
    }

    /// The Python line picked (by default: one with an update, else the newest supported).
    var chosenPython: String {
        if !pythonVersion.isEmpty { return pythonVersion }
        if let line = store.devUpdates.python.first(where: { $0.value.update })?.key { return line }
        return store.pythonLines.first?.version ?? ""
    }
    /// Installed state of the picked line: nil when it isn't installed.
    var pickedInfo: ToolUpdate? { store.devUpdates.python[chosenPython] }
    var detail: String {
        guard tool == "python" else { return L("toolDetail.\(tool)") }
        let installed = store.devUpdates.python.sorted { $0.key.compare($1.key, options: .numeric) == .orderedDescending }
        guard !installed.isEmpty else { return L("toolDetail.python") }
        return String(format: L("tools.pythonInstalled"), installed.map { $0.value.update ? String(format: L("tools.pythonLineUpdate"), $0.value.installed, $0.value.latest) : $0.value.installed }.joined(separator: " · "))
    }
    var confirmTitle: String {
        if tool == "python" {
            return pickedInfo.map { String(format: L("tools.updatePython"), $0.installed, $0.latest) } ?? String(format: L("tools.installPython"), store.pythonLines.first { $0.version == chosenPython }?.latest ?? chosenPython)
        }
        let verb = (status?.installed == true && status?.broken != true) ? L("tools.update") : L("setup.install")
        return "\(verb) \(L("tool.\(tool)"))"
    }

    /// One picker and one button that always matches what's picked.
    @ViewBuilder private var pythonControls: some View {
        if !store.pythonLines.isEmpty {
            Picker("", selection: Binding(get: { chosenPython }, set: { pythonVersion = $0 })) {
                ForEach(store.pythonLines) { line in
                    let info = store.devUpdates.python[line.version]
                    Text(info == nil ? "Python \(line.latest ?? line.version)" : String(format: L("tools.pythonPickInstalled"), line.latest ?? line.version)).tag(line.version)
                }
            }
            .labelsHidden().fixedSize().controlSize(.small)
            Group {
                if let info = pickedInfo, !info.update {
                    Label(L("tools.upToDate"), systemImage: "checkmark.circle.fill").font(.uiCaption.weight(.medium)).foregroundStyle(Brand.success)
                } else {
                    Button { confirming = true } label: {
                        if let info = pickedInfo { Label(String(format: L("tools.updateTo"), info.latest), systemImage: "arrow.down.circle") }
                        else { Text(L("setup.install")) }
                    }
                    .controlSize(.small).buttonStyle(.borderedProminent)
                    .disabled(busy || store.devTools["uv"]?.installed != true)
                    .help(store.devTools["uv"]?.installed == true ? "" : L("tools.needsUv"))
                }
            }
            .transition(.opacity)
            .animation(.snappy(duration: 0.2), value: chosenPython)
        }
    }

    @ViewBuilder private var action: some View {
        switch tool {
        case "php", "node", "jdk":
            Button(L("setup.install")) { store.showSetup = false; store.route = .language(tool == "jdk" ? "java" : tool) }
                .controlSize(.small).buttonStyle(.borderedProminent)
        case "clt":
            Button(L("setup.install")) { store.installAppleTools() }.controlSize(.small).buttonStyle(.borderedProminent)
        case "python":
            EmptyView()
        case let id where DevToolInstaller.automatic.contains(id):
            Button(L("setup.install")) { confirming = true }
                .controlSize(.small).buttonStyle(.borderedProminent).disabled(busy)
                .accessibilityIdentifier("tool.install.\(id)")
        default:
            if let page = DevToolSource.pages[tool], let url = URL(string: page) {
                Button { NSWorkspace.shared.open(url) } label: { Label(L("tools.official"), systemImage: "arrow.up.right.square") }
                    .controlSize(.small)
            }
        }
    }
}
