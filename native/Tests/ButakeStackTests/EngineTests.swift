import Foundation
import Testing
@testable import ButakeStack

@Test func listsProjectsThroughEngine() async throws {
    let engine = StackEngine()
    let result: [Project] = try await engine.call(["method": "listProjects"])
    #expect(result.isEmpty)
    do {
        let _: Bool = try await engine.call(["method": "unknown"])
        Issue.record("Unknown method should fail")
    } catch let error as EngineFailure {
        #expect(error.code == "invalid_request")
        #expect(error.errorDescription == L("engine.requestFailed"))
    }
}
