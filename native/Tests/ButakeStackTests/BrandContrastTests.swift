import ButakeDesign
import Foundation
import Testing
@testable import ButakeStack

// WCAG contrast of every state color used as text, in every theme of the app: 4.5:1 on the page and
// on the surface and on the state's own tint (chip 12 %, Increase Contrast 22 %); 3:1 for the same
// color as an icon or an edge. Fails when a palette or the shading changes under the minimum.

@MainActor private let themes: [(String, Theme)] = [
    ("Butake claro", .butakeLight), ("Butake oscuro", .butakeDark),
    ("Drácula claro", .draculaLight), ("Drácula oscuro", .draculaDark),
]

@MainActor private func states(_ theme: Theme) -> [(String, HexColor)] {
    [("éxito", theme.addition), ("aviso", theme.warning), ("error", theme.deletion), ("información", theme.modified), ("especial", theme.renamed)]
}

@Test @MainActor func contrastMathMatchesWCAG() {
    #expect(abs(Contrast.ratio(HexColor(0x000000), HexColor(0xFFFFFF)) - 21) < 0.001)
    #expect(abs(Contrast.ratio(HexColor(0x777777), HexColor(0xFFFFFF)) - 4.48) < 0.01)
    #expect(Contrast.ratio(HexColor(0x123456), HexColor(0x123456)) == 1)
}

@Test @MainActor func stateTextReadsOnEveryGroundInEveryTheme() {
    for (name, theme) in themes {
        for (state, color) in states(theme) {
            for fill in [Contrast.chipFill, Contrast.strongFill] {
                let text = Contrast.readable(color, isDark: theme.isDark, over: Brand.grounds(for: theme), fill: fill)
                for ground in Brand.grounds(for: theme) {
                    let tint = Contrast.composite(color, opacity: fill, over: ground)
                    #expect(Contrast.ratio(text, tint) >= Contrast.text, "\(name) · \(state) · relleno \(fill) sobre \(ground.value)")
                }
            }
        }
    }
}

@Test @MainActor func stateColorStaysEnoughForIconsAndEdges() {
    for (name, theme) in themes {
        for (state, color) in states(theme) {
            for ground in Brand.grounds(for: theme) {
                #expect(Contrast.ratio(color, ground) >= Contrast.nonText, "\(name) · \(state) como icono sobre \(ground.value)")
            }
        }
    }
}

@Test @MainActor func darkThemesOnlyLightenStateText() {
    for (_, theme) in themes where theme.isDark {
        for (state, color) in states(theme) {
            let text = Contrast.readable(color, isDark: true, over: Brand.grounds(for: theme))
            #expect(Contrast.luminance(text) >= Contrast.luminance(color), "\(state) oscuro se oscureció")
        }
    }
}

@Test @MainActor func lightThemesShadeStateTextOnly() {
    let theme = Theme.butakeLight
    let before = Contrast.ratio(theme.addition, Contrast.composite(theme.addition, opacity: Contrast.chipFill, over: Brand.backgroundColor(for: theme)))
    #expect(before < Contrast.text)
    let text = Contrast.readable(theme.addition, isDark: false, over: Brand.grounds(for: theme))
    #expect(text != theme.addition)
    #expect(Contrast.luminance(text) < Contrast.luminance(theme.addition))
}
