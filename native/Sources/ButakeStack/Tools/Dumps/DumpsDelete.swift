import Foundation

extension StackStore {
    /// Removes one dump in the engine (it keeps them in memory). False when it could not be asked
    /// or the engine no longer had it; the list follows the engine either way.
    func deleteDump(_ id: Int) async -> Bool {
        var removed = false
        await run(L("busy.saving")) {
            removed = try await self.call(["method": "dumpsDelete", "dump": id])
        }
        dumps.removeAll { $0.id == id }
        return removed
    }
}
