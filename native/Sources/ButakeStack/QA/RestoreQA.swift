#if DEBUG
import Foundation

/// Screenshots of «Restaurar configuración…» (BUTAKE_QA_RESTORE=<exported file>): the plan of that
/// file read by the engine, as the open panel would leave it, without the panel.
extension QAHooks {
    static func openRestore(_ path: String) {
        Task {
            try? await Task.sleep(for: .seconds(2))
            let store = StackStore.shared
            guard let bytes = try? Data(contentsOf: URL(fileURLWithPath: path)),
                  let data = try? JSONDecoder().decode(JSONValue.self, from: bytes),
                  let plan: RestorePlan = try? await store.call(["method": "planRestore", "data": data.any]) else { return }
            store.restoreRequest = RestoreRequest(data: data, plan: plan, folder: URL(fileURLWithPath: path).deletingLastPathComponent())
        }
    }
}
#endif
