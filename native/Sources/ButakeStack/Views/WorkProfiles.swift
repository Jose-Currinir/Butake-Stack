import AppKit
import SwiftUI

struct DevToolStatus: Decodable, Sendable, Hashable {
    let installed: Bool
    let version: String?
    var broken: Bool? = nil
}

/// What someone works on, and what each kind of work needs on the Mac.
struct WorkProfile: Identifiable, Hashable {
    let id: String
    let logo: String
    let tools: [String]

    static let all: [WorkProfile] = [
        WorkProfile(id: "laravel", logo: "laravel", tools: ["php", "node", "clt"]),
        WorkProfile(id: "web", logo: "astro", tools: ["node", "clt"]),
        WorkProfile(id: "cloudflare", logo: "emdash", tools: ["node", "wrangler", "cloudflared"]),
        WorkProfile(id: "python", logo: "django", tools: ["uv", "clt"]),
        WorkProfile(id: "rust", logo: "rust", tools: ["rustup", "clt"]),
        WorkProfile(id: "swift", logo: "swift", tools: ["xcode", "clt"]),
        WorkProfile(id: "android", logo: "android", tools: ["jdk", "android-studio", "android-sdk"]),
        WorkProfile(id: "kmp", logo: "kmp", tools: ["jdk", "android-studio", "android-sdk", "xcode"]),
        WorkProfile(id: "react-native", logo: "react-native", tools: ["node", "watchman", "cocoapods", "xcode", "android-studio", "jdk"]),
        WorkProfile(id: "github", logo: "github", tools: ["gh"]),
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
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 5), spacing: 8) {
                ForEach(WorkProfile.all) { profile in
                    ProfileChip(profile: profile, selected: chosen.contains(profile.id)) { toggle(profile.id) }
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

private struct ToolRow: View {
    @Bindable var store: StackStore
    let tool: String
    var status: DevToolStatus? { tool == "clt" ? DevToolStatus(installed: store.appleTools, version: nil) : store.devTools[tool] }
    var body: some View {
        HStack(spacing: 10) {
            TechLogo(tech: .of(tool == "jdk" ? "java" : tool), size: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("tool.\(tool)")).font(.uiCallout)
                Text(L("toolDetail.\(tool)")).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 10)
            if let status, status.installed, status.broken != true {
                Label(status.version ?? L("setup.ready"), systemImage: "checkmark.circle.fill").font(.uiCaption.weight(.medium)).foregroundStyle(Brand.success)
            } else {
                if status?.broken == true {
                    Label(L("tools.broken"), systemImage: "exclamationmark.triangle.fill").font(.uiCaption.weight(.medium)).foregroundStyle(Brand.warning)
                        .help(L("tools.brokenHelp"))
                }
                action
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var action: some View {
        switch tool {
        case "php", "node", "jdk":
            Button(L("setup.install")) { store.showSetup = false; store.route = .language(tool == "jdk" ? "java" : tool) }
                .controlSize(.small).buttonStyle(.borderedProminent)
        case "clt":
            Button(L("setup.install")) { store.installAppleTools() }.controlSize(.small).buttonStyle(.borderedProminent)
        default:
            if let page = DevToolSource.pages[tool], let url = URL(string: page) {
                Button { NSWorkspace.shared.open(url) } label: { Label(L("tools.official"), systemImage: "arrow.up.right.square") }
                    .controlSize(.small)
            }
        }
    }
}
