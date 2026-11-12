import Foundation

struct EngineFailure: Codable, LocalizedError { var code: String; var messageKey: String; var errorDescription: String? { L(messageKey) } }
private struct EngineResponse<T: Decodable>: Decodable { var ok: Bool; var value: T?; var error: EngineFailure? }

actor StackEngine {
    let executableURL: URL
    init(executable: URL = StackEngine.executable) { self.executableURL = executable }
    static var executable: URL {
        if let override = ProcessInfo.processInfo.environment["BUTAKE_STACK_ENGINE"] { return URL(fileURLWithPath: override) }
        return Bundle.main.resourceURL!.appendingPathComponent("butake-stack")
    }
    func call<T: Decodable>(_ parameters: [String: Any], as type: T.Type = T.self) async throws -> T {
        try await call(json: try JSONSerialization.data(withJSONObject: parameters), as: type)
    }
    /// Variant for main-actor callers: the request is serialized before crossing into the actor.
    func call<T: Decodable>(json input: Data, as: T.Type = T.self) async throws -> T {
        let executable = executableURL
        // Each call blocks on pipes until the engine exits (network operations can take minutes). On Swift's
        // cooperative pool a handful of slow calls starved every other task; these run on their own Dispatch queue.
        let output: Data = try await withCheckedThrowingContinuation { continuation in
            StackEngine.queue.async {
                do { continuation.resume(returning: try StackEngine.run(executable, input)) } catch { continuation.resume(throwing: error) }
            }
        }
        let response = try JSONDecoder().decode(EngineResponse<T>.self, from: output)
        if let value = response.value, response.ok { return value }
        throw response.error ?? EngineFailure(code: "engine", messageKey: "engine.requestFailed")
    }
    private static let queue = DispatchQueue(label: "cl.butake.stack.engine", qos: .userInitiated, attributes: .concurrent)
    private static let readers = DispatchQueue(label: "cl.butake.stack.engine.pipes", qos: .userInitiated, attributes: .concurrent)
    /// Writing to an engine that already exited must fail with an error, not kill the app with SIGPIPE.
    private static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()
    private final class Buffer: @unchecked Sendable { var data = Data() }
    private static func run(_ executable: URL, _ input: Data) throws -> Data {
        _ = ignoreBrokenPipes
        let process = Process()
        process.executableURL = executable
        let stdout = Pipe(); let stderr = Pipe(); let stdin = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = stderr
        try process.run()
        // stderr and stdin move on their own threads: neither pipe can fill up and stall the other.
        let diagnostic = Buffer(); let pipes = DispatchGroup()
        readers.async(group: pipes) { diagnostic.data = stderr.fileHandleForReading.readDataToEndOfFile() }
        readers.async(group: pipes) { try? stdin.fileHandleForWriting.write(contentsOf: input); try? stdin.fileHandleForWriting.close() }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        pipes.wait()
        if process.terminationStatus != 0 && output.isEmpty { throw EngineFailure(code: "engine", messageKey: "engine.requestFailed") }
        return output
    }
}
