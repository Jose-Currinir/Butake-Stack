import SwiftUI

/// «¿Con qué trabajas?»: a switch per kind of work, by category, and below what the chosen ones need
/// with its state on this Mac. Nothing is installed without asking.
struct WorkStep: View {
    @Bindable var store: StackStore
    @AppStorage("setup.profiles") private var profilesRaw = ""
    /// What most people who start with Stack work on: marked by «Marcar lo habitual».
    static let usual: Set<String> = ["laravel", "web"]
    /// The first time the step opens with nothing marked, what the detected projects ask for is marked.
    @AppStorage("setup.profilesSuggested") private var suggested = false
    var chosen: Set<String> { Set(profilesRaw.split(separator: ",").map(String.init)) }
    var suggestions: [ProfileSuggestion] { ProfileDetection.suggestions(for: store.projects) }
    /// PHP, Node and Apple's tools have their own rows in the next step, with their versions.
    var tools: [String] {
        var seen = Set<String>()
        return WorkProfile.all.filter { chosen.contains($0.id) }.flatMap(\.tools).filter { !["php", "node", "clt"].contains($0) && seen.insert($0).inserted }
    }

    var body: some View {
        Form {
            Section {
                Button { profilesRaw = chosen.union(Self.usual).sorted().joined(separator: ",") } label: {
                    Label(L("profiles.usual"), systemImage: Symbols.success)
                }
                .disabled(Self.usual.isSubset(of: chosen))
                .accessibilityIdentifier("profiles.usual")
            } footer: {
                Text(L("profiles.usualDetail")).font(.uiCaption).foregroundStyle(.secondary)
            }
            if !suggestions.isEmpty {
                Section {
                    ForEach(suggestions) { suggestion in
                        Label {
                            Text(String(format: L("profiles.detectedReason"), L("profile.\(suggestion.profile)"),
                                        suggestion.projects.formatted(.list(type: .and)), L("profile.\(suggestion.profile).detail")))
                        } icon: {
                            Image(systemName: chosen.contains(suggestion.profile) ? Symbols.success : Symbols.project)
                        }
                        .font(.uiCallout)
                        .accessibilityIdentifier("profiles.detected.\(suggestion.profile)")
                    }
                    Button { profilesRaw = ProfileDetection.marked(chosen, adding: suggestions).sorted().joined(separator: ",") } label: {
                        Label(L("profiles.detectedMark"), systemImage: Symbols.success)
                    }
                    .disabled(Set(suggestions.map(\.profile)).isSubset(of: chosen))
                    .accessibilityIdentifier("profiles.detectedMark")
                } header: {
                    Text(L("profiles.detected"))
                }
            }
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
        .onAppear {
            if !suggested && profilesRaw.isEmpty && !suggestions.isEmpty {
                profilesRaw = ProfileDetection.marked([], adding: suggestions).sorted().joined(separator: ",")
            }
            suggested = true
        }
    }

    private func binding(_ id: String) -> Binding<Bool> {
        Binding(get: { chosen.contains(id) }, set: { on in
            var set = chosen
            if on { set.insert(id) } else { set.remove(id) }
            profilesRaw = set.sorted().joined(separator: ",")
        })
    }
}
