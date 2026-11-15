import AppKit
import SwiftUI

/// The language version for a new project, as rows of a grouped form: the installed lines the
/// framework supports (the newest one proposed), the others apart with a warning, and what the
/// framework asks for under the row's title. When no installed line fits, a row offers to install one.
struct VersionChoice: View {
    @Bindable var store: StackStore
    let language: String
    let detail: String
    let installed: [String]
    let requirement: FrameworkRequirement?
    let proposed: String?
    /// What the chosen framework line asks for, when the framework has lines.
    var note: String? = nil
    @Binding var selection: String
    /// Opens the language's version picker.
    let install: () -> Void
    func compatible(_ line: String) -> Bool { requirement.map { $0.compatible.contains(line) } ?? true }
    var chosen: String? { selection.isEmpty ? proposed : selection }
    private var subtitle: String {
        if let note { return note }
        if let requirement, !requirement.requirement.isEmpty {
            return String(format: L("new.requires"), L("kind.\(requirement.framework)"), "\(requirement.language == "php" ? "PHP" : "Python") \(requirement.requirement)")
        }
        return detail
    }
    var body: some View {
        Picker(selection: $selection) {
            if let proposed { Text(String(format: L("new.proposed"), "\(language) \(proposed)")).tag("") }
            ForEach(installed.filter(compatible), id: \.self) { line in
                Text("\(language) \(line)").tag(line)
            }
            let others = installed.filter { !compatible($0) }
            if !others.isEmpty {
                Divider()
                ForEach(others, id: \.self) { Text(String(format: L("new.incompatible"), "\(language) \($0)")).tag($0) }
            }
        } label: {
            Text(language)
            Text(subtitle)
        }
        .help(detail)
        .accessibilityIdentifier("new.version.\(language.lowercased())")
        if let chosen, !compatible(chosen) {
            warning(String(format: L("new.incompatibleWarning"), "\(language) \(chosen)", requirement?.requirement ?? ""))
        } else if let requirement, !installed.contains(where: compatible) {
            warning(String(format: L("new.noCompatible"), language, requirement.compatible.first ?? ""))
        }
    }
    private func warning(_ text: String) -> some View {
        LabeledContent {
            Button(action: install) { Label(L("new.install"), systemImage: Symbols.install) }
                .buttonStyle(.bordered).accessibilityIdentifier("new.installVersion.\(language.lowercased())")
        } label: {
            Label(text, systemImage: Symbols.warning).foregroundStyle(Brand.warning)
        }
    }
}

/// The framework's supported lines as a menu: the ones that run on the chosen language line can
/// be picked (the newest of them is proposed); the rest say what they need and are off.
struct FrameworkVersionChoice: View {
    let kind: String
    let language: String
    let versions: [FrameworkVersion]
    let chosenLanguage: String?
    let selected: String?
    let select: (String) -> Void
    private func fits(_ version: FrameworkVersion) -> Bool { chosenLanguage.map { version.compatible.contains($0) } ?? true }
    var body: some View {
        let current = versions.first { $0.cycle == selected }
        Picker(selection: Binding(get: { selected ?? "" }, set: select)) {
            ForEach(versions) { version in
                Text(title(version)).tag(version.cycle).disabled(!fits(version))
                    .accessibilityIdentifier("new.framework.\(version.cycle)")
            }
        } label: {
            Text(String(format: L("new.frameworkVersion"), L("kind.\(kind)")))
            if let current {
                Text(String(format: L("new.frameworkFits"), current.latest ?? current.cycle, "\(language) \(Self.range(current.requirement))"))
            }
        }
        .accessibilityIdentifier("new.frameworkVersion")
    }
    private func title(_ version: FrameworkVersion) -> String {
        let name = "\(L("kind.\(kind)")) \(version.cycle)" + (version.isLts ? " · LTS" : "")
        return fits(version) ? name : "\(name) — " + String(format: L("new.frameworkNeeds"), "\(language) \(Self.range(version.requirement))")
    }
    /// ">=3.12,<=3.15" -> "3.12–3.15"; ">=3.10" -> "3.10 o más nueva".
    static func range(_ requirement: String) -> String {
        let parts = requirement.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        let low = parts.first { $0.hasPrefix(">=") }.map { String($0.dropFirst(2)) }
        let high = parts.first { $0.hasPrefix("<=") }.map { String($0.dropFirst(2)) }
        switch (low, high) {
        case let (l?, h?): return "\(l)–\(h)"
        case let (l?, nil): return String(format: L("new.orNewer"), l)
        default: return requirement
        }
    }
}
