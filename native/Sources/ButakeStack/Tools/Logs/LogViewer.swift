import AppKit
import SwiftUI

/// The one log view of the app: live lines of a supervised process, read through a `LogsBrowser`
/// (filter, level, paused, cleared). In Registros the page's toolbar has the actions; a project's
/// log tab (`LiveLog`) brings its own beside the filter.
struct LogViewer: View {
    @Bindable var store: StackStore
    let id: String
    @Bindable var browser: LogsBrowser
    /// Follow, copy and Finder beside the filter (outside Registros).
    var ownActions = false
    var minHeight: CGFloat = 320
    @State private var follow = true

    var body: some View {
        let visible = browser.lines(store, id)
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                FilterField(text: $browser.filter, identifier: "logs.filter", prompt: L("logs.filter"))
                Text(String(format: L("logs.count"), visible.count)).font(.uiCaption.monospacedDigit()).foregroundStyle(.secondary)
                    .accessibilityIdentifier("logs.count")
                if ownActions {
                    Toggle(isOn: $follow) { Label(L("logs.follow"), systemImage: Symbols.follow).labelStyle(.iconOnly) }
                        .toggleStyle(.button).help(L("logs.follow")).accessibilityIdentifier("logs.follow")
                    Button { browser.copy(store, id) } label: { Label(L("common.copy"), systemImage: Symbols.copy).labelStyle(.iconOnly) }
                        .help(L("common.copy")).accessibilityIdentifier("logs.copy")
                    Button { LogViewer.reveal(id) } label: { Label(L("logs.reveal"), systemImage: Symbols.folder).labelStyle(.iconOnly) }
                        .help(L("logs.reveal")).accessibilityIdentifier("logs.reveal")
                }
            }
            .padding(10)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        if visible.isEmpty {
                            Text(L("logs.empty")).font(.uiCallout).foregroundStyle(.secondary).padding(.vertical, 8)
                        }
                        ForEach(Array(visible.enumerated()), id: \.offset) { index, line in
                            Text(line).font(.uiSubheadline.monospaced()).textSelection(.enabled).id(index)
                        }
                    }
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: visible, initial: true) { _, current in
                    let following = ownActions ? follow : !browser.isPaused(id)
                    if following && !current.isEmpty { proxy.scrollTo(current.count - 1, anchor: .bottom) }
                }
            }
            .frame(minHeight: minHeight)
            .accessibilityIdentifier("logs.text")
        }
        .task(id: WatchID(process: id, running: store.daemonRunning)) {
            await store.watchLogs(id)
        }
    }

    private struct WatchID: Equatable {
        let process: String
        let running: Bool
    }

    /// The process's log file (`logs/<id>.log`) selected in Finder.
    static func reveal(_ id: String) {
        let file = Folder.baseURL.appendingPathComponent("logs/\(id).log")
        if FileManager.default.fileExists(atPath: file.path) { NSWorkspace.shared.activateFileViewerSelecting([file]) }
        else { Folder.open("logs") }
    }
}

/// A process's log inside a page (a project's Registros tab), following the end.
struct LiveLog: View {
    @Bindable var store: StackStore
    let id: String
    @State private var browser = LogsBrowser()
    var body: some View {
        LogViewer(store: store, id: id, browser: browser, ownActions: true, minHeight: 420).workSurface(radius: 14)
    }
}

/// A process a page points at (a sheet's item).
struct LogTarget: Identifiable { let id: String }
