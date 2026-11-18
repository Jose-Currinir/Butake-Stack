import Foundation

/// Accessibility settings forced for screenshots (debug builds with BUTAKE_QA_WINDOW), so the Mac's
/// own settings don't have to be touched (SwiftUI's environment values for them can't be set):
///     BUTAKE_QA_CONTRAST=increased   as System Settings › Accessibility › Display › Increase contrast
///     BUTAKE_QA_REDUCE_MOTION=1      as Reduce motion
enum QAAccessibility {
    #if DEBUG
    static let increasedContrast = ProcessInfo.processInfo.environment["BUTAKE_QA_WINDOW"] != nil && ProcessInfo.processInfo.environment["BUTAKE_QA_CONTRAST"] == "increased"
    static let reduceMotion = ProcessInfo.processInfo.environment["BUTAKE_QA_WINDOW"] != nil && ProcessInfo.processInfo.environment["BUTAKE_QA_REDUCE_MOTION"] == "1"
    #else
    static let increasedContrast = false
    static let reduceMotion = false
    #endif
}
