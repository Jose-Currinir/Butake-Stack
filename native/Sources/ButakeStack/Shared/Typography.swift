import SwiftUI

// Text styles that ButakeDesign does not define, on its same scale: at 1× they are the system
// text styles; at any other size, the macOS point size of the style times the user's factor.
// This file is the only place where point sizes are written (scripts/lint-ui.sh skips it).
@MainActor extension Font {
    private static func scaledStyle(_ style: Font, _ points: CGFloat, weight: Font.Weight? = nil, design: Font.Design? = nil) -> Font {
        TextScale.shared.factor == 1 ? style : .system(size: TextScale.points(points), weight: weight, design: design)
    }

    /// Big figures and the hero of an empty or finished state.
    static var uiLargeTitle: Font { scaledStyle(.largeTitle, 26) }
    /// Page and sheet titles.
    static var uiTitle: Font { scaledStyle(.title, 22) }
    /// Secondary lines under a title or a row.
    static var uiSubheadline: Font { scaledStyle(.subheadline, 11) }
    /// Code, paths, keys and values meant to be read character by character.
    static var uiMonospaced: Font { scaledStyle(.body.monospaced(), 13, design: .monospaced) }

    /// A drawing at a fixed scale whose text does not follow the user's text size: the boxes of the
    /// database diagram sit on a fixed grid, and the terminal's preview shows the exact point size
    /// being chosen.
    static func drawing(_ points: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        .system(size: points, weight: weight, design: design)
    }
}
