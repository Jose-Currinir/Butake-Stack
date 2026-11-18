import Foundation

/// BUTAKE_QA_PALETTE=<text> opens the palette (QAHooks) with that text typed, for screenshots.
enum PaletteQA {
    static var query: String? {
        #if DEBUG
        return ProcessInfo.processInfo.environment["BUTAKE_QA_PALETTE"].flatMap { $0.isEmpty ? nil : $0 }
        #else
        return nil
        #endif
    }
}
