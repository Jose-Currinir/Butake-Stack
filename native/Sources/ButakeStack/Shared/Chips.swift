import AppKit
import SwiftUI

/// Small colored label: state words, versions, counts.
struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary
    var help: String?
    @Environment(\.self) private var environment
    @Environment(\.colorScheme) private var scheme
    @Environment(\.colorSchemeContrast) private var contrast

    /// The tint as text: shaded until it reads at 4.5:1 on its own fill (Contrast.readable).
    private var textColor: Color {
        let grounds = Brand.grounds(for: Brand.theme)
        let resolved = tint.resolve(in: environment)
        let opaque = Contrast.composite(HexColor(resolved: resolved), opacity: Double(resolved.opacity), over: grounds[0])
        return Contrast.readable(opaque, isDark: scheme == .dark, over: grounds,
                                 fill: Contrast.increased(contrast) ? Contrast.strongFill : Contrast.chipFill).color
    }

    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.uiCaption2.weight(.bold)) }
            Text(text).font(.uiCaption.weight(.semibold))
        }
        .foregroundStyle(textColor)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .tintedFill(tint, fill: Contrast.chipFill, in: Capsule())
        .help(help ?? "")
    }
}

extension Chip {
    /// The environment a project runs with.
    init(env: EnvEnvironment) {
        self.init(text: env.title, symbol: env.kind.symbol, tint: env.kind.color, help: String(format: L("env.activeHelp"), env.title))
    }

    /// Where a language version stands in its support cycle.
    @MainActor init(cycle: Cycle) {
        let until = cycle.eolDate.map { " · " + String(format: L("lifecycle.until"), $0) } ?? ""
        switch cycle.status {
        case .lts: self.init(text: "LTS" + until, symbol: "shield.fill", tint: Brand.success)
        case .active: self.init(text: L("lifecycle.active") + until, symbol: Symbols.active, tint: Brand.info)
        case .maintenance: self.init(text: L("lifecycle.maintenance") + until, symbol: "wrench.adjustable", tint: Brand.warning)
        case .ended: self.init(text: L("lifecycle.ended"), symbol: Symbols.error, tint: Brand.danger)
        }
    }

    /// When a vault item expires, or that it already did.
    @MainActor init(expiry item: VaultItem, date: Date) {
        let expiry = item.expiry() ?? .ok
        let text = expiry == .expired ? String(format: L("vault.expiredOn"), Format.shortDate(date))
            : String(format: L("vault.expiresOn"), Format.shortDate(date))
        self.init(text: text, symbol: expiry == .ok ? "calendar" : Symbols.warning,
                  tint: expiry == .expired ? Brand.danger : expiry == .soon ? Brand.warning : .secondary)
    }
}
