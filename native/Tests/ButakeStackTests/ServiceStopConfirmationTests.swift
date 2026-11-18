import Testing
@testable import ButakeStack

/// Turning a service off from the menu bar panel asked twice (the panel and the window) and brought the window
/// forward: each surface now asks only for the stops asked from it.
@Test func onlyTheSurfaceAStopCameFromAsksForIt() {
    let fromPanel = ServiceStopRequest(service: "mysql", users: "Demo", surface: .panel)
    let fromWindow = ServiceStopRequest(service: "mysql", users: "Demo")
    #expect(ServiceStopConfirmation.asks(fromPanel, on: .panel))
    #expect(!ServiceStopConfirmation.asks(fromPanel, on: .window))
    #expect(ServiceStopConfirmation.asks(fromWindow, on: .window))
    #expect(!ServiceStopConfirmation.asks(fromWindow, on: .panel))
    #expect(!ServiceStopConfirmation.asks(nil, on: .window))
}
