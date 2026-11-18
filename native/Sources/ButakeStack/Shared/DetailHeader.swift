import SwiftUI

/// The head of a page that shows one thing (a project, a language, a category of services): its logo,
/// its name in large type, one line under it (kind, version, address) and the page's own actions with
/// their words, the main one last. Where the window is narrow the actions go under the name instead of
/// being cut. The page's tabs, when it has them, go right below (`DetailTabs`).
///
/// ```swift
/// DetailHeader(title: project.name) {
///     TechLogo(tech: project.tech, size: DetailHeaderLogo.size)
/// } subtitle: {
///     Text(project.kindLine)              // «Laravel · PHP 8.4»
/// } actions: {
///     Button(L("menu.openInBrowser")) { … }
///     Button(L("menu.stop")) { … }.buttonStyle(.borderedProminent)
/// }
/// ```
struct DetailHeader<Logo: View, Subtitle: View, Actions: View>: View {
    let title: String
    @ViewBuilder var logo: Logo
    @ViewBuilder var subtitle: Subtitle
    @ViewBuilder var actions: Actions

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .center, spacing: 12) {
                identity
                Spacer(minLength: 16)
                actionRow
            }
            VStack(alignment: .leading, spacing: 10) {
                identity
                actionRow
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("page.header")
    }

    private var identity: some View {
        HStack(spacing: 12) {
            logo
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.uiTitle.weight(.semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .accessibilityAddTraits(.isHeader)
                    .accessibilityIdentifier("page.header.title")
                subtitle
                    .font(.uiSubheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) { actions }
            .fixedSize()
            .accessibilityIdentifier("page.header.actions")
    }
}

extension DetailHeader where Subtitle == EmptyView {
    init(title: String, @ViewBuilder logo: () -> Logo, @ViewBuilder actions: () -> Actions) {
        self.init(title: title, logo: logo, subtitle: { EmptyView() }, actions: actions)
    }
}

/// The tabs of a page with a `DetailHeader`, under it and aligned with its text: a segmented control
/// while they fit, a menu where the window is narrow. One divider below sets the header apart.
struct DetailTabs<Tab: Hashable & Identifiable>: View {
    let tabs: [Tab]
    @Binding var selection: Tab
    let title: (Tab) -> String
    /// The control's name for VoiceOver and its tooltip («Pestañas del proyecto»).
    let label: String

    var body: some View {
        VStack(spacing: 0) {
            ViewThatFits(in: .horizontal) {
                picker.pickerStyle(.segmented)
                picker.pickerStyle(.menu)
            }
            .labelsHidden()
            .fixedSize()
            .help(label)
            .padding(.horizontal, 20)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
        }
        .accessibilityIdentifier("page.tabs")
    }

    private var picker: some View {
        Picker(label, selection: $selection) {
            ForEach(tabs) { Text(title($0)).tag($0) }
        }
    }
}

/// The side of a `DetailHeader`'s logo: it grows with the text size (⌘+ / ⌘−) like the title next to it.
enum DetailHeaderLogo {
    static var size: CGFloat { TextScale.points(40) }
}
