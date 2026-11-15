import AppKit
import SwiftUI

/// Small colored label: state words, versions, counts.
struct Chip: View {
    let text: String
    var symbol: String?
    var tint: Color = .secondary
    var help: String?
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.uiCaption2.weight(.bold)) }
            Text(text).font(.uiCaption.weight(.semibold))
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 7).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule())
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
