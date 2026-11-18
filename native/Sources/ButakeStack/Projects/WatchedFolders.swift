import AppKit
import SwiftUI

struct WatchedFolder: Decodable, Sendable, Hashable, Identifiable {
    let path: String
    let ignored: [String]
    var id: String { path }
}

struct WatchedScan: Decodable, Sendable {
    let root: String
    let missing: Bool
    let scan: FolderScan?
}

/// New projects in a watched folder: offered, never added without asking.
struct WatchBanner: View {
    @Bindable var store: StackStore
    let scan: FolderScan
    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: Symbols.newFolder, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(String(format: L("watch.banner"), scan.projects.count, scan.name)).font(.uiHeadline).lineLimit(2)
                Text(scan.projects.prefix(4).map { URL(fileURLWithPath: $0.detection.project.path).lastPathComponent }.joined(separator: ", "))
                    .font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Button(L("watch.ignore")) { Task { await store.ignoreWatched(scan.root, paths: scan.projects.map(\.detection.project.path)) } }
                .controlSize(.small).accessibilityIdentifier("watch.ignore")
            Button(L("watch.review")) { store.reviewWatched(scan) }
                .buttonStyle(.borderedProminent).controlSize(.small).accessibilityIdentifier("watch.review")
        }
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(Brand.info.opacity(0.1))
        .overlay(alignment: .top) { Divider() }
        .transitioned(.move(edge: .bottom).combined(with: .opacity))
    }
}
