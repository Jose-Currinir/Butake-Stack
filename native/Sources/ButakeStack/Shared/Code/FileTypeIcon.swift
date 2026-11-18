import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The file icons of Material Icon Theme (MIT), bundled in `FileIcons/` with their license
/// (`LICENSE-material-icon-theme.txt`). The map is read on first use and every icon is loaded the
/// first time a file of its kind is shown, then kept.
@MainActor final class FileIconCatalog {
    static let shared = FileIconCatalog()

    private struct Mapping: Decodable {
        var file: String
        var names: [String: String]
        var extensions: [String: String]
        var lightNames: [String: String]
        var lightExtensions: [String: String]
    }

    private lazy var mapping: Mapping? = Bundle.module.url(forResource: "map", withExtension: "json", subdirectory: "FileIcons")
        .flatMap { try? Data(contentsOf: $0) }
        .flatMap { try? JSONDecoder().decode(Mapping.self, from: $0) }
    private var images: [String: NSImage] = [:]
    private var missing: Set<String> = []
    private var typeNames: [String: String] = [:]

    /// Icon of a path: its exact file name first, then the longest dotted suffix ("blade.php" before
    /// "php"), then the generic file. Light variants exist for icons that would vanish on white.
    func iconName(for path: String, light: Bool) -> String? {
        guard let mapping else { return nil }
        let name = (path as NSString).lastPathComponent.lowercased()
        if light, let icon = mapping.lightNames[name] { return icon }
        if let icon = mapping.names[name] { return icon }
        var parts = name.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.first == "" { parts.removeFirst() } // ".env.example" → ["env", "example"]
        for start in (name.hasPrefix(".") ? 0 : 1)..<max(parts.count, 1) where start < parts.count {
            let suffix = parts[start...].joined(separator: ".")
            if light, let icon = mapping.lightExtensions[suffix] { return icon }
            if let icon = mapping.extensions[suffix] { return icon }
        }
        return mapping.file
    }

    func image(for path: String, light: Bool) -> NSImage? {
        guard let name = iconName(for: path, light: light), !missing.contains(name) else { return nil }
        if let cached = images[name] { return cached }
        guard let url = Bundle.module.url(forResource: name, withExtension: "svg", subdirectory: "FileIcons"),
              let image = NSImage(contentsOf: url) else { missing.insert(name); return nil }
        images[name] = image
        return image
    }

    /// What the file is, in the system's words ("Código fuente Swift"), for VoiceOver.
    func typeName(for path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        if let known = typeNames[ext] { return known }
        let name = UTType(filenameExtension: ext)?.localizedDescription ?? L("git.icon.file")
        typeNames[ext] = name
        return name
    }

    /// Icons loaded so far (for the performance tests).
    var loadedCount: Int { images.count }
}

/// The icon of a file by its name and extension. The one API for file icons of the app.
struct FileTypeIcon: View {
    let path: String
    var size: CGFloat = 16
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let catalog = FileIconCatalog.shared
        Group {
            if let image = catalog.image(for: path, light: scheme == .light) {
                // No tooltip: the icon sits in every file row and a tooltip per row slows long lists.
                Image(nsImage: image).resizable().interpolation(.high).aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: Symbols.file).resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(catalog.typeName(for: path))
    }
}
