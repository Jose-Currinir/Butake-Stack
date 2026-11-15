import Foundation

struct EngineFailure: Codable, LocalizedError {
    var code: String
    var messageKey: String
    /// The database's own message (failed statement, refused login), when there is one.
    var detail: String?
    var errorDescription: String? {
        // GitHub limited this network: the detail is the minutes until it resets.
        if code == "source_rate_limited" { return String(format: L(messageKey), detail ?? "60") }
        return detail.map { "\(L(messageKey)): \($0)" } ?? L(messageKey)
    }
    /// The engine's code as it travels inside other answers ("source_rate_limited:12").
    init(code: String) {
        let (name, detail) = code.split(separator: ":", maxSplits: 1).map(String.init).splitFirst()
        self.code = name
        self.messageKey = "error.\(name)"
        self.detail = detail
    }
    init(code: String, messageKey: String, detail: String? = nil) {
        self.code = code; self.messageKey = messageKey; self.detail = detail
    }
    /// What to tell the user about any error of a call.
    static func message(_ error: Error) -> String {
        (error as? EngineFailure)?.errorDescription ?? L("engine.requestFailed")
    }
}
private extension Array where Element == String {
    func splitFirst() -> (String, String?) { (first ?? "", count > 1 ? self[1] : nil) }
}
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
        try Task.checkCancellation()
        return try decode(try await output(input, run: nil), as: T.self)
    }

    /// A call the caller may stop: cancelling its task sends SIGTERM to the engine process, which
    /// ends what it started (engine/src/core/watch.rs) and exits; the call then throws
    /// `CancellationError`. Only for requests that wait on the user or the network and change
    /// nothing until they finish (AWS CLI); a write is never cut halfway.
    func stoppableCall<T: Decodable>(json input: Data, as: T.Type = T.self) async throws -> T {
        try Task.checkCancellation()
        let run = EngineRun()
        do {
            // Not named `output`: older compilers (Xcode 26.6) crash on a constant that shares the
            // name of the method called in its own initializer.
            let answer = try await withTaskCancellationHandler {
                try await self.output(input, run: run)
            } onCancel: {
                run.stop()
            }
            return try decode(answer, as: T.self)
        } catch {
            // Whatever the stopped engine answered (or not), a stop reads as one.
            try Task.checkCancellation()
            throw error
        }
    }

    private func output(_ input: Data, run: EngineRun?) async throws -> Data {
        let executable = executableURL
        // Each call blocks on pipes until the engine exits (network operations can take minutes). On Swift's
        // cooperative pool a handful of slow calls starved every other task; these run on their own Dispatch queue.
        return try await withCheckedThrowingContinuation { continuation in
            StackEngine.queue.addOperation {
                do { continuation.resume(returning: try StackEngine.run(executable, input, run)) } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func decode<T: Decodable>(_ output: Data, as: T.Type) throws -> T {
        try Task.checkCancellation()
        let response = try JSONDecoder().decode(EngineResponse<T>.self, from: output)
        if let value = response.value, response.ok { return value }
        throw response.error ?? EngineFailure(code: "engine", messageKey: "engine.requestFailed")
    }
    nonisolated func statusStream() -> AsyncThrowingStream<StackStatus, Error> {
        snapshots(["watch-status"])
    }

    nonisolated func logStream(_ id: String) -> AsyncThrowingStream<[String], Error> {
        snapshots(["watch-logs", id])
    }

    nonisolated func dumpStream() -> AsyncThrowingStream<[DumpEntry], Error> {
        snapshots(["watch-dumps"])
    }

    private nonisolated func snapshots<T: Decodable & Sendable>(_ arguments: [String]) -> AsyncThrowingStream<T, Error> {
        let executable = executableURL
        return AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice

            // Read chunks as soon as the pipe is readable. A snapshot must not wait for
            // the helper to exit or for a buffered async byte iterator to fill.
            do {
                try process.run()
            } catch {
                continuation.finish(throwing: error)
                return
            }
            continuation.onTermination = { _ in
                if process.isRunning { process.terminate() }
            }
            StackEngine.readers.async {
                defer {
                    if process.isRunning { process.terminate() }
                    process.waitUntilExit()
                }
                do {
                    let decoder = JSONDecoder()
                    var pending = Data()
                    let handle = output.fileHandleForReading
                    while true {
                        let chunk = handle.availableData
                        if chunk.isEmpty { break }
                        pending.append(chunk)
                        var start = pending.startIndex
                        while let end = pending[start...].firstIndex(of: 0x0A) {
                            let value = try decoder.decode(T.self, from: Data(pending[start..<end]))
                            if case .terminated = continuation.yield(value) { return }
                            start = pending.index(after: end)
                        }
                        pending.removeSubrange(..<start)
                        guard pending.count <= 20 * 1024 * 1024 else {
                            throw EngineFailure(code: "engine_response_too_large", messageKey: "engine.responseTooLarge")
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "cl.butake.stack.engine"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 8
        return queue
    }()
    private static let readers = DispatchQueue(label: "cl.butake.stack.engine.pipes", qos: .userInitiated, attributes: .concurrent)
    /// Writing to an engine that already exited must fail with an error, not kill the app with SIGPIPE.
    private static let ignoreBrokenPipes: Void = { signal(SIGPIPE, SIG_IGN) }()
    private static func run(_ executable: URL, _ input: Data, _ run: EngineRun?) throws -> Data {
        _ = ignoreBrokenPipes
        let process = Process()
        process.executableURL = executable
        let stdout = Pipe()
        let stdin = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        run?.started(process)

        let pipes = DispatchGroup()
        readers.async(group: pipes) {
            try? stdin.fileHandleForWriting.write(contentsOf: input)
            try? stdin.fileHandleForWriting.close()
        }
        let output: Data
        do {
            var data = Data()
            let handle = stdout.fileHandleForReading
            let limit = 64 * 1024 * 1024
            while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
                guard data.count + chunk.count <= limit else {
                    throw EngineFailure(code: "engine_response_too_large", messageKey: "engine.responseTooLarge")
                }
                data.append(chunk)
            }
            output = data
        } catch {
            if process.isRunning { process.terminate() }
            try? stdout.fileHandleForReading.close()
            throw error
        }
        process.waitUntilExit()
        pipes.wait()
        if process.terminationStatus != 0 && output.isEmpty { throw EngineFailure(code: "engine", messageKey: "engine.requestFailed") }
        return output
    }
}

/// The engine process of a stoppable call: stopping before it starts stops it as soon as it does.
final class EngineRun: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var stopped = false

    func started(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        if stopped, process.isRunning { process.terminate() }
    }

    /// SIGTERM to the engine (never SIGKILL: it must end its children first).
    func stop() {
        lock.lock(); defer { lock.unlock() }
        stopped = true
        if let process, process.isRunning { process.terminate() }
    }
}
