#if DEBUG
import Foundation

/// Screenshots of the extensions (P-43): the sheet open over the service's page or the project's
/// Resumen (BUTAKE_QA_EXTENSION_SHEET=<id of the catalog>|browser|carry|resolve).
extension QAHooks {
    static var extensionSheet: String? {
        StackStore.qaWindow ? ProcessInfo.processInfo.environment["BUTAKE_QA_EXTENSION_SHEET"] : nil
    }
}
#endif
