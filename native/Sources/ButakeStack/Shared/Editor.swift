import AppKit
import SwiftUI

/// Opens a folder in the first code editor installed, or in Terminal.
enum Editor {
    static let candidates = ["com.todesktop.230313mzl4w4u92", "com.microsoft.VSCode", "dev.zed.Zed", "com.jetbrains.PhpStorm", "com.sublimetext.4"]
    static func open(_ path: String) {
        let folder = URL(fileURLWithPath: path)
        for id in candidates {
            if let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                NSWorkspace.shared.open([folder], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
                return
            }
        }
        NSWorkspace.shared.open(folder)
    }
    static func terminal(_ path: String) {
        NSWorkspace.shared.open([URL(fileURLWithPath: path)], withApplicationAt: URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app"), configuration: NSWorkspace.OpenConfiguration())
    }
}
