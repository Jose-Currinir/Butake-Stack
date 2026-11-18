import OSLog
import ServiceManagement

/// Stack itself opens at login (menu bar only, no window: the app is LSUIElement and its main window
/// is suppressed at launch), next to the session agent that serves the projects. «Iniciar con la
/// sesión» turns both on and off. A failure here (an app that is not in Applications, a user who
/// removed it in Ajustes del Sistema) never fails the switch: the agent is what serves projects.
@MainActor enum LoginItem {
    private static let log = Logger(subsystem: "cl.butake.stack.native", category: "login")

    /// What to do with the app's own login item when the session agent changes.
    enum Action: Equatable { case register, unregister, nothing }

    static func action(agentOn: Bool, status: SMAppService.Status) -> Action {
        switch (agentOn, status) {
        case (true, .notRegistered), (true, .notFound): .register
        case (false, .enabled), (false, .requiresApproval): .unregister
        default: .nothing
        }
    }

    static func sync(agentOn: Bool) {
        // A bare binary (tests, `swift run`) is no app: there is nothing to register.
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        let service = SMAppService.mainApp
        do {
            switch action(agentOn: agentOn, status: service.status) {
            case .register: try service.register()
            case .unregister: try service.unregister()
            case .nothing: break
            }
        } catch {
            log.error("login item: \(String(describing: error), privacy: .public)")
        }
    }
}
