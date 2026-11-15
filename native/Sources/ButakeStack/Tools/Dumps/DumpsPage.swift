import SwiftUI

/// `dump()` calls of the projects, like the console dumper: the list is in the window's content
/// column (`DumpsList`) and this is the one selected. With none, what a project needs to send them.
struct DumpsPage: View {
    @Bindable var store: StackStore
    @Bindable var browser = DumpsBrowser.shared
    var port: Int { store.dumpsStatus?.port ?? store.config?.dumps?.port ?? 9912 }
    var setupLines: [String] { ["VAR_DUMPER_FORMAT=server"] + (port == 9912 ? [] : ["VAR_DUMPER_SERVER=127.0.0.1:\(port)"]) }

    var body: some View {
        VStack(spacing: 0) {
            if let owner = store.dumpsStatus?.busy { ReceiverConflict(port: port, owner: owner) }
            Group {
                if let id = browser.selection, let dump = browser.entries(store).first(where: { $0.id == id }) {
                    DumpDetail(dump: dump).id(dump.id)
                } else if browser.entries(store).isEmpty {
                    ContentUnavailableView {
                        Label(L("dumps.setupTitle"), systemImage: Symbols.debugDump)
                    } description: {
                        Text(String(format: L("dumps.setupDetail"), port))
                    } actions: {
                        ToolSetup(lines: setupLines, footer: L("dumps.envHelp"), identifier: "dumps.setup")
                    }
                } else {
                    ContentUnavailableView(L("dumps.choose"), systemImage: Symbols.debugDump)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .toolbar {
            if #available(macOS 26, *) {
                // Apart from the window's own «+» (new project).
                ToolbarSpacer(.fixed, placement: .primaryAction)
            }
            ToolbarItemGroup(placement: .primaryAction) {
                Toggle(isOn: Binding(get: { browser.frozen != nil }, set: { browser.frozen = $0 ? store.dumps : nil })) {
                    Label(L("dumps.pause"), systemImage: Symbols.pause)
                }
                .toggleStyle(.button).help(L("dumps.pauseHelp")).accessibilityIdentifier("dumps.toolbar.pause")
                Button {
                    Task {
                        await store.clearDumps()
                        browser.selection = nil
                        if browser.frozen != nil { browser.frozen = [] }
                    }
                } label: { Label(L("dumps.clear"), systemImage: Symbols.clearView) }
                    .disabled(browser.entries(store).isEmpty).help(L("dumps.clearHelp")).accessibilityIdentifier("dumps.toolbar.clear")
                ToolSetupButton(lines: setupLines, footer: L("dumps.envHelp"), identifier: "dumps")
                ReceiverOptionsButton(tool: "dumps", store: store)
            }
        }
        .task(id: store.daemonRunning) { await store.watchDumps() }
        .onChange(of: browser.entries(store).first?.id) { _, newest in
            // The newest is shown while nothing else was chosen, like a console following its end.
            if browser.selection == nil || !browser.entries(store).contains(where: { $0.id == browser.selection }) { browser.selection = newest }
        }
    }
}

/// A dump: where it was called (opens in the editor), from which request or command, when, and
/// its text.
private struct DumpDetail: View {
    let dump: DumpEntry
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 4) {
                if let source = dump.source, let place = dump.place {
                    GridRow {
                        label(L("dumps.file"))
                        Button { Editor.open(source.file) } label: { Label(place, systemImage: Symbols.editor) }
                            .buttonStyle(.link).help(source.file).accessibilityIdentifier("dumps.detail.open")
                    }
                }
                if let origin = dump.origin, !origin.isEmpty {
                    GridRow { label(L("dumps.origin")); Text(origin).font(.uiCallout.monospaced()).textSelection(.enabled).lineLimit(2) }
                }
                if let time = dump.time {
                    GridRow {
                        label(L("dumps.time"))
                        Text(Date(timeIntervalSince1970: time), format: .dateTime.day().month().hour().minute().second()).font(.uiCallout).monospacedDigit()
                    }
                }
            }
            .padding(16)
            Divider()
            ScrollView {
                Text(dump.lines.joined(separator: "\n")).font(.uiCallout.monospaced()).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(16)
            }
            .accessibilityIdentifier("dumps.text")
        }
    }

    private func label(_ text: String) -> some View {
        Text(text).font(.uiCallout).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }
}
