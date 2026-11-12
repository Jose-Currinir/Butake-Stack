import AppKit
import SwiftUI

/// Glass surface on macOS 26+ (Liquid Glass), regular material before.
struct GlassCard: ViewModifier {
    var radius: CGFloat = 16
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content.background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        }
    }
}
extension View {
    func glassCard(radius: CGFloat = 16) -> some View { modifier(GlassCard(radius: radius)) }
}

/// Ring that fills with the state. It only animates when the state changes: a menu bar app must
/// not keep the GPU busy with endless pulses.
struct StatusRing: View {
    let phase: ProcessPhase
    var size: CGFloat = 12
    var body: some View {
        ZStack {
            Circle().stroke(phase.color.opacity(0.25), lineWidth: size * 0.18)
            Circle().trim(from: 0, to: phase == .running ? 1 : (phase == .starting ? 0.6 : 0.0001))
                .stroke(phase.color, style: StrokeStyle(lineWidth: size * 0.18, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if phase == .running {
                Circle().fill(phase.color).frame(width: size * 0.4, height: size * 0.4).transition(.scale.combined(with: .opacity))
            }
        }
        .frame(width: size, height: size)
        .animation(.snappy, value: phase)
        .accessibilityLabel(L("state.\(phase.rawValue)"))
    }
}

/// Clickable card: lifts on hover, sinks when pressed, reachable with the keyboard like any button.
struct CardButtonStyle: ButtonStyle {
    var radius: CGFloat = 16
    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration, radius: radius)
    }
    private struct CardButtonBody: View {
        let configuration: Configuration
        let radius: CGFloat
        @State private var hovering = false
        var body: some View {
            configuration.label
                .contentShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
                .scaleEffect(configuration.isPressed ? 0.985 : (hovering ? 1.012 : 1))
                .shadow(color: .black.opacity(hovering ? 0.2 : 0.07), radius: hovering ? 12 : 5, y: 4)
                .onHover { hovering = $0 }
                .animation(.snappy(duration: 0.18), value: hovering)
                .animation(.snappy(duration: 0.12), value: configuration.isPressed)
        }
    }
}

/// Inicio: how everything is doing at a glance, with sites and services one click away.
struct HomePage: View {
    @Bindable var store: StackStore
    @State private var previews = SitePreviews.shared
    var services: [String] { ["web"] + Route.allEngines.filter { store.engineVersion($0) != nil } }
    var online: Int { store.projects.filter { store.sitePhase($0) == .running }.count }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                hero
                if !store.projects.isEmpty {
                    SectionHeading(title: L("route.sites"), detail: String(format: L("sites.online"), online))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 320), spacing: 18)], spacing: 18) {
                        ForEach(store.projects) { project in
                            HomeSiteCard(store: store, project: project, previews: previews)
                        }
                        AddSiteCard { store.showNewProject = true }
                    }
                } else {
                    AddSiteCard { store.showNewProject = true }.frame(maxWidth: 320)
                }
                SectionHeading(title: L("sidebar.services"), detail: String(format: L("status.engines"), store.runningEngines, store.engineCount))
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 300), spacing: 14)], spacing: 14) {
                    ForEach(services, id: \.self) { name in ServiceTile(store: store, name: name) }
                }
            }
            .padding(28)
            .frame(maxWidth: 1200, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.background)
    }

    private var hero: some View {
        let healthy = store.daemonRunning && store.health == .green
        return HStack(spacing: 18) {
            ZStack {
                Circle().fill(LinearGradient(colors: [Brand.accent.opacity(0.35), Brand.accent.opacity(0.08)], startPoint: .topLeading, endPoint: .bottomTrailing))
                Image(systemName: healthy ? "checkmark.seal.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 30, weight: .semibold, design: .rounded))
                    .foregroundStyle(healthy ? Brand.accent : Brand.warning)
                    .symbolEffect(.bounce, value: healthy)
            }
            .frame(width: 64, height: 64)
            VStack(alignment: .leading, spacing: 4) {
                Text(healthy ? L("home.allGood") : (store.daemonRunning ? L("home.attention") : L("daemon.stopped")))
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                Text(online == 0 && !store.projects.isEmpty
                     ? String(format: L("home.summaryAllOff"), store.projects.count, store.runningEngines)
                     : String(format: L("home.summary"), online, store.projects.count, store.runningEngines))
                    .font(.uiCallout).foregroundStyle(.secondary)
            }
            Spacer()
            if !store.daemonRunning {
                Button { Task { await store.startDaemon() } } label: { Label(L("daemon.start"), systemImage: "play.fill") }.buttonStyle(.borderedProminent)
            }
        }
        .padding(22)
        .glassCard(radius: 22)
    }
}

struct SectionHeading: View {
    let title: String
    var detail: String?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(title).font(.system(size: 17, weight: .semibold, design: .rounded))
            if let detail { Text(detail).font(.uiCaption).foregroundStyle(.secondary) }
        }
    }
}

private struct HomeSiteCard: View {
    @Bindable var store: StackStore
    let project: Project
    let previews: SitePreviews
    var body: some View {
        let phase = store.sitePhase(project)
        // The card opens the site; the switch sits on top of it so it never triggers the card.
        Button { withAnimation(.smooth(duration: 0.3)) { store.openSite(project.id) } } label: {
            VStack(alignment: .leading, spacing: 0) {
                SitePreview(project: project, previews: previews, height: 140)
                    .clipShape(UnevenRoundedRectangle(topLeadingRadius: 16, topTrailingRadius: 16, style: .continuous))
                    .overlay(alignment: .topLeading) {
                        if let info = store.git[project.id] { GitChip(info: info).padding(8) }
                    }
                HStack(spacing: 10) {
                    TechLogo(tech: project.tech, size: 26)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(project.title).font(.system(size: 13.5, weight: .semibold, design: .rounded)).lineLimit(1)
                        Text(project.php.map { "\(project.tech.title) · PHP \($0)" } ?? project.tech.title).font(.uiCaption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 76)
                }
                .padding(12)
            }
            .glassCard()
        }
        .buttonStyle(CardButtonStyle())
        .overlay(alignment: .bottomTrailing) {
            HStack(spacing: 8) {
                Toggle("", isOn: Binding(get: { project.enabled }, set: { on in Task { await store.setSite(project, enabled: on) } }))
                    .toggleStyle(.switch).controlSize(.small).labelsHidden()
                    .accessibilityLabel(String(format: L("site.powerFor"), project.title))
                StatusRing(phase: phase)
            }
            .padding(.horizontal, 12).padding(.vertical, 17)
        }
        .contextMenu { SiteMenuItems(store: store, project: project, previews: previews) }
        .accessibilityLabel(project.title)
        .accessibilityValue(project.enabled ? L("state.\(phase.rawValue)") : L("site.off"))
        .accessibilityIdentifier("home.site.\(project.id)")
    }
}

/// Branch and pending changes of a site's repository, as a small glass chip.
struct GitChip: View {
    let info: GitInfo
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 9, weight: .bold))
            Text(info.branch.isEmpty ? L("git.detached") : info.branch).lineLimit(1)
            if info.changes > 0 { Text("· \(info.changes)").foregroundStyle(Brand.warning) }
            if info.ahead > 0 { Text("↑\(info.ahead)") }
            if info.behind > 0 { Text("↓\(info.behind)") }
        }
        .font(.system(size: 10.5, weight: .semibold).monospacedDigit())
        .foregroundStyle(.white)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.black.opacity(0.55), in: Capsule())
        .help(String(format: L("git.help"), info.branch, info.changes))
        .accessibilityElement(children: .combine)
    }
}

/// The same actions wherever a site appears (cards, sidebar, panel): one menu, one order.
struct SiteMenuItems: View {
    let store: StackStore
    let project: Project
    var previews: SitePreviews = .shared
    var body: some View {
        Button { Task { await store.setSite(project, enabled: !project.enabled) } } label: {
            Label(project.enabled ? L("palette.stop") : L("palette.start"), systemImage: "power")
        }
        Divider()
        Button { if let url = project.url { NSWorkspace.shared.open(url) } } label: { Label(L("site.browser"), systemImage: "safari") }
        Button { Editor.open(project.path) } label: { Label(L("site.editor"), systemImage: "chevron.left.forwardslash.chevron.right") }
        Button { Editor.terminal(project.path) } label: { Label(L("site.terminal"), systemImage: "terminal") }
        if ButakeGit.installed {
            Button { ButakeGit.open(project.path) } label: { Label(L("git.open"), systemImage: "arrow.triangle.branch") }
        }
        Button { NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.path) } label: { Label(L("site.finder"), systemImage: "folder") }
        Divider()
        Button { previews.refresh(project) } label: { Label(L("site.refreshPreview"), systemImage: "camera") }
    }
}

private struct AddSiteCard: View {
    let action: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 24, weight: .semibold, design: .rounded)).foregroundStyle(Brand.accent)
                Text(L("sites.addEllipsis")).font(.uiCallout.weight(.medium))
            }
            .frame(maxWidth: .infinity, minHeight: 190)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Brand.accent.opacity(hovering ? 0.7 : 0.35), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .accessibilityIdentifier("home.addSite")
    }
}

private struct ServiceTile: View {
    @Bindable var store: StackStore
    let name: String
    var body: some View {
        let isWeb = name == "web"
        let phase = isWeb ? store.phase("stack.caddy") : (store.engineEnabled(name) ? store.phase("stack.\(name)") : .stopped)
        Button { store.route = .service(Route.category(of: name)) } label: {
            HStack(spacing: 12) {
                TechLogo(tech: .of(name), size: 34)
                VStack(alignment: .leading, spacing: 1) {
                    Text(Tech.of(name).title).font(.system(size: 13.5, weight: .semibold, design: .rounded))
                    Text(isWeb ? "Caddy · 80/443" : "\(store.engineVersion(name) ?? "") · \(store.enginePort(name).map(String.init) ?? "")")
                        .font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                }
                Spacer(minLength: 60)
            }
            .padding(14)
            .glassCard(radius: 14)
        }
        .buttonStyle(CardButtonStyle(radius: 14))
        .overlay(alignment: .trailing) {
            Group {
                if isWeb {
                    StatusRing(phase: phase, size: 14)
                } else {
                    Toggle("", isOn: Binding(get: { store.engineEnabled(name) }, set: { on in Task { await store.setEngine(name, enabled: on) } }))
                        .toggleStyle(.switch).controlSize(.small).labelsHidden().accessibilityLabel(Tech.of(name).title)
                }
            }
            .padding(.trailing, 14)
        }
        .contextMenu {
            if !isWeb {
                Button { Task { await store.setEngine(name, enabled: !store.engineEnabled(name)) } } label: {
                    Label(store.engineEnabled(name) ? L("palette.stop") : L("palette.start"), systemImage: "power")
                }
            }
            Button { store.route = .service(Route.category(of: name)) } label: { Label(L("palette.openPage"), systemImage: "arrow.right.circle") }
        }
        .accessibilityIdentifier("home.service.\(name)")
    }
}
