import AppKit
import SwiftUI

/// What is wrong with the skills and their links, one row per finding with the button that fixes it.
/// Nothing changes by itself: a fix opens the same confirmation as any change to an assistant's folder.
struct SkillsHealthPanel: View {
    let tool: SkillsTool

    var body: some View {
        if tool.problems.isEmpty {
            ContentUnavailableView {
                Label(L("skills.health.ok"), systemImage: Symbols.success)
            } description: {
                Text(L("skills.health.okDetail"))
            } actions: {
                Button { Task { await tool.load() } } label: { Label(L("skills.health.check"), systemImage: Symbols.reload) }
                    .buttonStyle(.bordered).accessibilityIdentifier("skills.health.check")
            }
            .accessibilityIdentifier("skills.health")
        } else {
            Form {
                ForEach(SkillProblem.Kind.allCases, id: \.self) { kind in
                    let members = tool.problems.filter { $0.kind == kind }
                    if !members.isEmpty {
                        Section {
                            ForEach(members) { SkillProblemRow(tool: tool, problem: $0) }
                        } header: {
                            Text(L("skills.problem.\(kind.rawValue)"))
                        } footer: {
                            SettingsFooter(L("skills.problem.\(kind.rawValue).detail"))
                        }
                    }
                }
            }
            .formStyle(.grouped).themedScroll()
            .accessibilityIdentifier("skills.health")
        }
    }
}

/// A finding: what it is about (a skill, an assistant, a path) and its fix.
struct SkillProblemRow: View {
    let tool: SkillsTool
    let problem: SkillProblem

    private var skill: Skill? { problem.skill.flatMap(tool.skill) }
    private var agent: SkillAgent? { problem.agent.flatMap(tool.agent) }

    private var title: String { skill?.name ?? agent?.name ?? problem.skill ?? problem.agent ?? "" }
    private var detail: String? {
        if let path = problem.path { return path.replacingOccurrences(of: NSHomeDirectory(), with: "~") }
        return skill.map(\.id)
    }

    var body: some View {
        LabeledContent {
            fix
        } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
        }
        .help(problem.kind == .agentPath ? L("skills.problem.agent_path.help") : (problem.path ?? ""))
        .accessibilityIdentifier("skills.health.problem.\(problem.id)")
    }

    @ViewBuilder private var fix: some View {
        switch problem.kind {
        case .noDescription, .unused:
            if let skill { button(L("skills.fix.\(problem.kind.rawValue)")) { tool.select(skill.id) } }
        case .brokenLink:
            if let skill, let agent {
                button(L("skills.fix.broken_link")) {
                    tool.requestLinks(SkillLinkRequest(skill: skill.id, changes: [SkillLinkChange(skill: skill.id, agent: agent.id, on: true)]))
                }
            } else if let path = problem.path {
                button(L("skills.fix.reveal")) { reveal(path) }
            }
        case .duplicateName:
            if let skill { button(L("skills.fix.duplicate_name")) { tool.sheet = .rename(skill.id) } }
        case .conflict:
            if let path = problem.path { button(L("skills.fix.reveal")) { reveal(path) } }
        case .agentPath:
            if let skill, let agent {
                button(L("skills.fix.agent_path")) {
                    tool.requestLinks(SkillLinkRequest(skill: skill.id, changes: [SkillLinkChange(skill: skill.id, agent: agent.id, on: true)]))
                }
            } else if let skill { button(L("skills.fix.unused")) { tool.select(skill.id) } }
        case .missingFolder:
            if let agent, !agent.builtin {
                button(L("skills.fix.missing_folder")) { tool.sheet = .agent(agent.id) }
            } else {
                button(L("skills.health.check")) { Task { await tool.load() } }
            }
        }
    }

    private func button(_ title: String, action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.bordered)
            .accessibilityIdentifier("skills.health.fix.\(problem.id)")
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
