import AppKit
import SwiftUI

/// Header of every page: logo, title, subtitle and the page's main controls.
struct PageHeader<Trailing: View>: View {
    let tech: Tech
    let title: String
    let subtitle: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 14) {
            TechLogo(tech: tech, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.ui(size: 20, weight: .semibold))
                Text(subtitle).font(.uiCallout).foregroundStyle(.secondary).lineLimit(2)
            }
            Spacer(minLength: 12)
            trailing
        }
        .padding(.vertical, 6)
    }
}

/// Preview image of a site, or its logo while there is none.
struct SitePreview: View {
    let project: Project
    let previews: SitePreviews
    var height: CGFloat = 150
    /// Whole page visible (fit) over a blurred copy, instead of filling and cropping.
    var fit = false
    var body: some View {
        ZStack {
            if let image = previews.image(for: project), fit {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(height: height).clipped().blur(radius: 28).opacity(0.7)
                Image(nsImage: image).resizable().scaledToFit()
                    .frame(height: height - 28)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.35), radius: 12, y: 6)
            } else if let image = previews.image(for: project) {
                Image(nsImage: image).resizable().scaledToFill()
                    .frame(height: height, alignment: .top).clipped()
            } else {
                Rectangle().fill(Color.primary.opacity(0.05))
                TechLogo(tech: project.tech, size: height * 0.3)
            }
            if previews.loading.contains(project.id) && previews.image(for: project) == nil {
                ProgressView().controlSize(.small).padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
            }
        }
        .frame(height: height)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// Scrolling page with the same width, padding and background everywhere.
struct PageScroll<Content: View>: View {
    var maxWidth: CGFloat = 1200
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) { content }
                .padding(28)
                .frame(maxWidth: maxWidth, alignment: .leading)
                .frame(maxWidth: .infinity)
        }
        .background(Brand.background)
    }
}

/// Titled card with an optional trailing control and footnote: the building block of every page.
struct CardBlock<Trailing: View, Content: View>: View {
    let title: String
    var symbol: String?
    var footer: String?
    @ViewBuilder var trailing: Trailing
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol).font(.uiCaption.weight(.semibold)) }
                Text(title).font(.uiCallout.weight(.semibold))
                Spacer()
                trailing
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 4)
            Card { content }
            if let footer {
                Text(footer).font(.uiCaption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }
}
extension CardBlock where Trailing == EmptyView {
    init(title: String, symbol: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.init(title: title, symbol: symbol, footer: footer, trailing: { EmptyView() }, content: content)
    }
}

/// A site that uses something (an engine, a language): its own logo and name, then a detail.
struct SiteLinkRow: View {
    let project: Project
    var detail: String = ""
    let go: () -> Void
    var body: some View {
        Button(action: go) {
            HStack(spacing: 10) {
                TechLogo(tech: project.tech, size: 24)
                Text(project.title)
                Spacer()
                Text(detail).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.right").font(.uiCaption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct Card<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) { content }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }
}

struct CardSection<Content: View>: View {
    let title: String
    var trailing: String?
    @ViewBuilder let content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.uiCallout.weight(.semibold)).foregroundStyle(.secondary)
                Spacer()
                if let trailing { Text(trailing).font(.uiCaption).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 4)
            Card { content }
        }
    }
}

struct SettingRow<Control: View>: View {
    let title: String
    @ViewBuilder let control: Control
    var body: some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            control
        }
        .frame(minHeight: 26)
    }
}

/// A technology the site uses; clicking goes to its page.
struct TechRow: View {
    let tech: Tech
    let value: String
    let go: () -> Void
    var body: some View {
        Button(action: go) {
            HStack(spacing: 10) {
                TechLogo(tech: tech, size: 24)
                Text(tech.title)
                Spacer()
                Text(value).foregroundStyle(.secondary).monospacedDigit()
                Image(systemName: "chevron.right").font(.uiCaption).foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct InfoRow: View {
    let symbol: String
    let title: String
    let value: String
    var body: some View {
        LabeledContent {
            Text(value).foregroundStyle(.primary).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
        } label: {
            Label(title, systemImage: symbol).foregroundStyle(.secondary)
        }
    }
}

/// Process with its state, log button and start/stop switch.
struct ProcessRow: View {
    let store: StackStore
    let id: String
    let process: ProjectProcess
    let showLog: (String) -> Void
    var body: some View {
        let phase = store.phase(id)
        HStack(spacing: 10) {
            Image(systemName: phase.symbol).foregroundStyle(phase.color).font(.ui(size: 11))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(process.name).font(.ui(size: 13, weight: .medium))
                    if process.autostart { Image(systemName: "bolt.fill").font(.ui(size: 9)).foregroundStyle(Brand.accent).help(L("process.autostart")) }
                }
                Text(process.commandLine).font(.ui(size: 10.5, design: .monospaced)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 6)
            Button { showLog(id) } label: { Image(systemName: "text.alignleft") }
                .buttonStyle(.borderless).help(L("process.logs")).accessibilityIdentifier("process.logs.\(id)")
            Toggle("", isOn: Binding(get: { phase == .running || phase == .starting }, set: { on in Task { await store.processAction(id, on ? "start" : "stop") } }))
                .toggleStyle(.switch).controlSize(.small).labelsHidden()
                .disabled(!store.daemonRunning)
                .accessibilityLabel(process.name)
                .accessibilityIdentifier("process.toggle.\(id)")
        }
    }
}

/// Opens a folder in the first code editor installed, or in Terminal.
enum Editor {
    static let candidates = ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed", "com.jetbrains.PhpStorm", "com.sublimetext.4"]
    static func open(_ path: String) {
        let folder = URL(fileURLWithPath: path)
        for id in candidates {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(folder)
    }
    static func terminal(_ path: String) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
    }
}

struct LogTarget: Identifiable { let id: String }

struct LogSheet: View {
    @Bindable var store: StackStore
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var filter = ""
    var lines: [String] { (store.logs[id] ?? []).filter { filter.isEmpty || $0.localizedCaseInsensitiveContains(filter) } }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                IconTile(symbol: "text.alignleft", size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(L("process.logs")).font(.uiHeadline)
                    Text(id).font(.ui(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                }
                Spacer()
                TextField(L("logs.filter"), text: $filter).textFieldStyle(.roundedBorder).frame(width: 200).accessibilityIdentifier("logs.filter")
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string) } label: { Image(systemName: "doc.on.doc") }
                    .help(L("logs.copy")).accessibilityIdentifier("logs.copy")
                Button(L("action.close")) { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(14)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.ui(size: 11.5, design: .monospaced)).textSelection(.enabled).id(index)
                        }
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: lines.count) { _, count in proxy.scrollTo(count - 1, anchor: .bottom) }
            }
            .background(Brand.surface).accessibilityIdentifier("logs.text")
        }
        .frame(width: 820, height: 500)
        .task {
            while !Task.isCancelled {
                await store.loadLogs(id)
                try? await Task.sleep(for: .seconds(1.5))
            }
        }
    }
}
