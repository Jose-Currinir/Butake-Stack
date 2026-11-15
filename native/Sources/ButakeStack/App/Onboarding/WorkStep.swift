import SwiftUI

/// «¿Con qué trabajas?»: a switch per kind of work, by category, and below what the chosen ones need
/// with its state on this Mac. Nothing is installed without asking.
struct WorkStep: View {
    @Bindable var store: StackStore
    @AppStorage("setup.profiles") private var profilesRaw = ""
    var chosen: Set<String> { Set(profilesRaw.split(separator: ",").map(String.init)) }
    /// PHP, Node and Apple's tools have their own rows in the next step, with their versions.
    var tools: [String] {
        var seen = Set<String>()
        return WorkProfile.all.filter { chosen.contains($0.id) }.flatMap(\.tools).filter { !["php", "node", "clt"].contains($0) && seen.insert($0).inserted }
    }

    var body: some View {
        Form {
            ForEach(WorkProfile.categories, id: \.self) { category in
                Section(L("category.work.\(category)")) {
                    ForEach(WorkProfile.all.filter { $0.category == category }) { profile in
                        Toggle(isOn: binding(profile.id)) {
                            Label {
                                Text(L("profile.\(profile.id)"))
                                Text(L("profile.\(profile.id).detail"))
                            } icon: {
                                TechLogo(tech: .of(profile.logo), size: 22)
                            }
                        }
                        .accessibilityIdentifier("profile.\(profile.id)")
                    }
                }
            }
            if !tools.isEmpty {
                Section(L("profiles.needs")) {
                    ForEach(tools, id: \.self) { ToolRow(store: store, tool: $0).padding(.horizontal, -12).padding(.vertical, -8) }
                }
            }
        }
        .formStyle(.grouped)
        // The sheet is the background: no second surface behind the sections.
        .scrollContentBackground(.hidden)
        .animation(.snappy(duration: 0.25), value: tools)
        .task { await store.refreshDevTools() }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { chosen.contains(id) }, set: { on in
            var set = chosen
            if on { set.insert(id) } else { set.remove(id) }
            profilesRaw = set.sorted().joined(separator: ",")
        })
    }
}
