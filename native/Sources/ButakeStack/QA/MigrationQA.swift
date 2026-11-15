#if DEBUG
import Foundation

/// Screenshots of «Mover los datos a la carpeta Stack…» (BUTAKE_QA_MIGRATION=row|plan|done): the row
/// in Ajustes › Avanzado, or the sheet over it with the plan the engine makes for the isolated home
/// (BUTAKE_DEVTOOLS_HOME) or with a made-up finished run. Nothing is ever moved from QA.
extension QAHooks {
    private static var migration: String? {
        StackStore.qaWindow ? ProcessInfo.processInfo.environment["BUTAKE_QA_MIGRATION"] : nil
    }
    static var dataMigration: Bool { migration != nil }
    static var dataMigrationSheet: Bool { migration == "plan" || migration == "done" }
    static var dataMigrationResult: Bool { migration == "done" }
}
#endif
