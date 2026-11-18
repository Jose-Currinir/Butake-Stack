import SwiftUI

/// Ayuda › Atajos de teclado: every shortcut of the registry, by menu, with a search.
struct ShortcutsSheet: View {
    @State var query = ""

    var body: some View {
        let sections = Shortcuts.sections(matching: query)
        SheetFrame(title: L("shortcuts.title"), symbol: Symbols.keyboard, detail: L("shortcuts.detail"), width: 520, height: 520,
                   actionTitle: L("common.done"), actionID: "shortcuts.done", action: { true }) {
            VStack(spacing: 10) {
                FilterField(text: $query, identifier: "shortcuts.search", prompt: L("shortcuts.search"))
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(sections, id: \.group) { section in
                            Text(section.group.title).font(.uiCaption.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.top, 8)
                            ForEach(section.items) { shortcut in
                                HStack {
                                    Text(shortcut.title).font(.uiBody)
                                    Spacer()
                                    Text(shortcut.display).font(.uiBody).fontDesign(.rounded).foregroundStyle(.secondary)
                                }
                                .padding(.vertical, 2)
                                .accessibilityElement(children: .combine)
                                .accessibilityIdentifier("shortcuts.row.\(shortcut.id)")
                            }
                        }
                        if sections.isEmpty {
                            Text(L("shortcuts.empty")).foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(30)
                        }
                    }
                    .padding(.horizontal, 6)
                }
                .frame(maxHeight: .infinity)
            }
        }
    }
}
