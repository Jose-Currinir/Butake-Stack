import SwiftUI

/// The setup assistant: a short welcome, «¿Con qué trabajas?» and the base Stack needs on this Mac.
/// It opens by itself on the first launch and while something is missing; Ayuda › «Asistente de
/// configuración…» is the only other way in. «Más tarde» closes it at any step.
struct SetupAssistantSheet: View {
    @Bindable var store: StackStore
    @AppStorage("welcome.seen") private var seen = false
    @State private var step: Step

    enum Step: Int, CaseIterable {
        case welcome, work, base
    }

    init(store: StackStore) {
        self.store = store
        _step = State(initialValue: Self.firstStep)
    }

    /// The welcome only the first time; afterwards the assistant opens on what is still missing.
    static var firstStep: Step {
        #if DEBUG
        if let step = QAHooks.setupStep.flatMap(Step.init(rawValue:)) { return step }
        #endif
        return UserDefaults.standard.bool(forKey: "welcome.seen") ? .base : .welcome
    }

    var title: String {
        switch step {
        case .welcome: L("assistant.welcome")
        case .work: L("profiles.question")
        case .base: L("setup.title")
        }
    }
    var detail: String {
        switch step {
        case .welcome: L("assistant.welcomeDetail")
        case .work: L("profiles.hint")
        case .base: L("setup.subtitle")
        }
    }

    var body: some View {
        SheetFrame(title: title, symbol: step == .welcome ? nil : (step == .work ? Symbols.project : Symbols.setup), detail: detail,
                   width: 720, height: 600,
                   actionTitle: step == .base ? L("common.done") : L("assistant.next"),
                   actionID: "assistant.next",
                   canAct: step != .base || store.setupComplete,
                   cancelID: step == .base && store.setupComplete ? nil : "assistant.later",
                   cancelTitle: L("setup.later"),
                   action: {
                       guard let next = Step(rawValue: step.rawValue + 1) else { return true }
                       step = next
                       return false
                   }) {
            Group {
                switch step {
                case .welcome: WelcomeStep()
                case .work: WorkStep(store: store)
                case .base: BaseStep(store: store)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } status: {
            HStack(spacing: 10) {
                if let previous = Step(rawValue: step.rawValue - 1) {
                    Button { step = previous } label: { Label(L("assistant.back"), systemImage: Symbols.back) }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("assistant.back")
                }
                Text(String(format: L("assistant.step"), step.rawValue + 1, Step.allCases.count))
                    .font(.uiCaption).foregroundStyle(.secondary).monospacedDigit()
                if let busy = store.busy {
                    ProgressView().controlSize(.small)
                    Text(busy).font(.uiCaption).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .onDisappear { seen = true }
    }
}

/// What Stack is, in one look: the languages and services it brings and three promises.
private struct WelcomeStep: View {
    let logos = ["php", "node", "python", "java", "rust", "swift", "mysql", "postgres", "redis"]
    var body: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 0)
            BrandMark(size: 96)
            HStack(spacing: 12) {
                ForEach(logos, id: \.self) { TechLogo(tech: .of($0), size: 34) }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 10) {
                ForEach(0..<3, id: \.self) { index in
                    Label(L("assistant.promise.\(index)"), systemImage: Symbols.success)
                        .font(.uiCallout).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }
}
