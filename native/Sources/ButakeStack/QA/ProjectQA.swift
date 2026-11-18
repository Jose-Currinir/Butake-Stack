#if DEBUG
import Foundation

/// Screenshots of a project's page (`BUTAKE_QA_ROUTE=site:<id>`): the tab it opens on
/// (BUTAKE_QA_PROJECT_TAB=summary|envs|processes|logs) and a sheet open over it
/// (BUTAKE_QA_PROJECT_SHEET=settings).
extension QAHooks {
    private static func projectValue(_ name: String) -> String? {
        StackStore.qaWindow ? ProcessInfo.processInfo.environment[name] : nil
    }
    static var projectTab: String? { projectValue("BUTAKE_QA_PROJECT_TAB") }
    static var projectSheet: String? { projectValue("BUTAKE_QA_PROJECT_SHEET") }
    /// The fixed address's sheet open over the summary (BUTAKE_QA_SHARE_SHEET=configure).
    static var shareSheet: String? { projectValue("BUTAKE_QA_SHARE_SHEET") }

    /// A folder's context menu as text (BUTAKE_QA_GROUP_MENU=<id>:<file>, several joined by ","):
    /// the same actions the menu draws, since a context menu does not open without a click.
    static func groupMenus() {
        guard let value = projectValue("BUTAKE_QA_GROUP_MENU") else { return }
        Task {
            try? await Task.sleep(for: .seconds(3))
            for target in value.split(separator: ",") {
                let parts = target.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let group = StackStore.shared.groups.first(where: { $0.id == parts[0] }) else { continue }
                let lines = StackStore.shared.groupActions(group).enumerated().flatMap { index, actions in
                    (index > 0 ? ["—"] : []) + actions.map { "\($0.title)\($0.enabled ? "" : "    [desactivado]")" }
                }
                let text = group.name + "\n" + lines.map { "    " + $0 }.joined(separator: "\n") + "\n"
                try? text.write(toFile: parts[1], atomically: true, encoding: .utf8)
            }
        }
    }
}
#endif
