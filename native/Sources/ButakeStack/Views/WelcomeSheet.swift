import SwiftUI

/// First launch: a short animated tour of what Stack does, ending in "Preparar Butake Stack".
/// It can be seen again from General. Motion follows the system's Reduce Motion setting.
struct WelcomeSheet: View {
    @Bindable var store: StackStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage("welcome.seen") private var seen = false
    // QA screenshots can open on a given page.
    @State private var page = StackStore.qaWindow ? UserDefaults.standard.integer(forKey: "welcome.qaPage") : 0
    @State private var forward = true
    static let pages = 4

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                AmbientBackground(page: page, still: reduceMotion)
                Group {
                    switch page {
                    case 0: IntroPage(still: reduceMotion)
                    case 1: SitesPage(still: reduceMotion)
                    case 2: VersionsPage(still: reduceMotion)
                    default: ServicesPage(still: reduceMotion)
                    }
                }
                .id(page)
                .transition(reduceMotion ? .opacity : .asymmetric(
                    insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
                    removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)))
                .padding(.horizontal, 48)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            footer
        }
        .frame(width: 780, height: 560)
    }

    private var footer: some View {
        HStack {
            Button(L("welcome.skip")) { finish() }
                .buttonStyle(.borderless).foregroundStyle(.secondary).opacity(page < Self.pages - 1 ? 1 : 0)
                .accessibilityIdentifier("welcome.skip")
            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<Self.pages, id: \.self) { index in
                    Capsule().fill(index == page ? Brand.accent : Color.primary.opacity(0.18))
                        .frame(width: index == page ? 22 : 7, height: 7)
                }
            }
            .animation(.snappy(duration: 0.3), value: page)
            Spacer()
            HStack(spacing: 8) {
                if page > 0 {
                    Button(L("welcome.back")) { go(page - 1) }.controlSize(.large)
                }
                Button(page == Self.pages - 1 ? L("welcome.start") : L("welcome.next")) {
                    page == Self.pages - 1 ? finish() : go(page + 1)
                }
                .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("welcome.next")
            }
            .frame(minWidth: 180, alignment: .trailing)
        }
        .padding(.horizontal, 22).padding(.vertical, 16)
        .background(.bar)
    }

    private func go(_ target: Int) {
        forward = target > page
        withAnimation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.5, dampingFraction: 0.86)) { page = target }
    }
    private func finish() {
        seen = true
        dismiss()
        // "Preparar" follows when this Mac still needs something.
        if !store.setupComplete {
            Task { try? await Task.sleep(for: .milliseconds(450)); store.showSetup = true }
        }
    }
}

// MARK: Pages

/// Content that rises into place, one element after the other.
private struct Rise: ViewModifier {
    let index: Int
    let still: Bool
    @State private var shown = false
    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || still ? 0 : 14)
            .scaleEffect(shown || still ? 1 : 0.97)
            .onAppear {
                withAnimation(still ? .easeOut(duration: 0.2) : .spring(response: 0.55, dampingFraction: 0.8).delay(0.08 + Double(index) * 0.07)) { shown = true }
            }
    }
}
private extension View {
    func rise(_ index: Int, _ still: Bool) -> some View { modifier(Rise(index: index, still: still)) }
}

private struct PageText: View {
    let title: String
    let detail: String
    let still: Bool
    var start = 0
    var body: some View {
        VStack(spacing: 8) {
            Text(title).font(.system(size: 28, weight: .bold, design: .rounded)).multilineTextAlignment(.center).rise(start, still)
            Text(detail).font(.ui(size: 14)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                .frame(maxWidth: 520).fixedSize(horizontal: false, vertical: true).rise(start + 1, still)
        }
    }
}

private struct IntroPage: View {
    let still: Bool
    @State private var landed = false
    @State private var glow = false
    let languages = ["php", "node", "python", "java", "rust", "swift"]
    var body: some View {
        VStack(spacing: 26) {
            ZStack {
                Circle().fill(Brand.accent.opacity(0.22)).frame(width: 150, height: 150).blur(radius: 30)
                    .scaleEffect(glow ? 1.12 : 0.9).opacity(landed ? 1 : 0)
                BrandMark(size: 96).shadow(color: .black.opacity(0.18), radius: 18, y: 8)
                    .scaleEffect(landed || still ? 1 : 0.4).rotationEffect(.degrees(landed || still ? 0 : -12)).opacity(landed ? 1 : 0)
            }
            PageText(title: L("welcome.intro.title"), detail: L("welcome.intro.detail"), still: still, start: 2)
            HStack(spacing: 14) {
                ForEach(Array(languages.enumerated()), id: \.element) { index, id in
                    TechLogo(tech: .of(id), size: 38).rise(4 + index, still)
                }
            }
        }
        .onAppear {
            withAnimation(still ? .easeOut(duration: 0.2) : .spring(response: 0.7, dampingFraction: 0.62)) { landed = true }
            if !still { withAnimation(.easeInOut(duration: 2.4).repeatForever(autoreverses: true).delay(0.6)) { glow = true } }
        }
    }
}

private struct SitesPage: View {
    let still: Bool
    @State private var running = false
    let sites: [(String, String, String)] = [("gestion", "laravel", "PHP 8.4"), ("tienda", "django", "Python 3.13"), ("blog", "astro", "Node 24")]
    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 8) {
                ForEach(Array(sites.enumerated()), id: \.offset) { index, site in
                    HStack(spacing: 12) {
                        TechLogo(tech: .of(site.1), size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 5) {
                                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Brand.success)
                                Text("https://\(site.0).test").font(.ui(size: 13, weight: .semibold)).monospaced()
                            }
                            Text(site.2).font(.uiCaption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Circle().fill(running ? Brand.success : Color.secondary.opacity(0.4)).frame(width: 9, height: 9)
                            .shadow(color: running ? Brand.success.opacity(0.7) : .clear, radius: 5)
                            .animation(.easeOut(duration: 0.4).delay(0.5 + Double(index) * 0.25), value: running)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(.background.opacity(0.85)))
                    .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
                    .rise(index, still)
                }
            }
            .frame(width: 420)
            PageText(title: L("welcome.sites.title"), detail: L("welcome.sites.detail"), still: still, start: 3)
        }
        .onAppear { running = true }
    }
}

private struct VersionsPage: View {
    let still: Bool
    let rows: [(String, String, String)] = [
        ("python", "Python 3.13", ".python-version"), ("node", "Node 24", ".nvmrc"),
        ("php", "PHP 8.4", "Global"), ("java", "Java 21", ".java-version"), ("rust", "Rust stable", "rust-toolchain.toml"),
    ]
    var body: some View {
        VStack(spacing: 26) {
            VStack(spacing: 7) {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 10) {
                        TechLogo(tech: .of(row.0), size: 24)
                        Text(row.1).font(.ui(size: 13, weight: .semibold)).monospacedDigit()
                        Spacer()
                        Chip(text: row.2, symbol: row.2 == "Global" ? "star.fill" : "doc.text", tint: row.2 == "Global" ? Brand.accent : .secondary)
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.background.opacity(0.85)))
                    .offset(x: index.isMultiple(of: 2) ? -8 : 8)
                    .rise(index, still)
                }
            }
            .frame(width: 400)
            PageText(title: L("welcome.versions.title"), detail: L("welcome.versions.detail"), still: still, start: 5)
        }
    }
}

private struct ServicesPage: View {
    let still: Bool
    let services = ["mysql", "postgres", "redis", "mongodb", "meilisearch", "web"]
    var body: some View {
        VStack(spacing: 26) {
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(64), spacing: 18), count: 3), spacing: 18) {
                ForEach(Array(services.enumerated()), id: \.element) { index, id in
                    TechLogo(tech: .of(id), size: 52)
                        .padding(6)
                        .background(Circle().fill(.background.opacity(0.7)))
                        .rise(index, still)
                }
            }
            PageText(title: L("welcome.services.title"), detail: L("welcome.services.detail"), still: still, start: 6)
            HStack(spacing: 16) {
                ForEach(Array(["checkmark.seal.fill", "lock.shield.fill", "hand.raised.fill"].enumerated()), id: \.offset) { index, symbol in
                    Label(L("welcome.promise.\(index)"), systemImage: symbol).font(.uiCaption.weight(.medium)).foregroundStyle(.secondary)
                        .rise(8 + index, still)
                }
            }
        }
    }
}

/// Soft colored light that drifts slowly behind the pages and shifts with each one.
private struct AmbientBackground: View {
    let page: Int
    let still: Bool
    @State private var drift = false
    var body: some View {
        GeometryReader { geo in
            ZStack {
                Circle().fill(Brand.accent.opacity(0.16)).frame(width: 340).blur(radius: 70)
                    .offset(x: (drift ? -60 : 40) + CGFloat(page) * 30, y: drift ? -90 : -40)
                Circle().fill(Brand.info.opacity(0.12)).frame(width: 300).blur(radius: 80)
                    .offset(x: drift ? 160 : 90, y: (drift ? 110 : 60) - CGFloat(page) * 20)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .animation(.spring(response: 1.2, dampingFraction: 0.9), value: page)
        }
        .onAppear { if !still { withAnimation(.easeInOut(duration: 7).repeatForever(autoreverses: true)) { drift = true } } }
        .allowsHitTesting(false)
    }
}
