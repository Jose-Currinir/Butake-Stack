import Foundation

/// Decides whether an environment file with secret values may be written into a folder (R9). It fails closed:
/// when Git cannot answer, the file is not written, because «Git did not run» must not read as «not a repository».
enum EnvDownloadGuard {
    enum Verdict: Equatable {
        /// Outside any repository, or inside one that ignores the file.
        case allowed
        /// Inside a repository that would track the file.
        case notIgnored
        /// Git could not be run or gave an answer that is not understood.
        case unverifiable
    }

    static let gitURL = URL(fileURLWithPath: "/usr/bin/git")

    nonisolated static func verdict(folder: String, name: String, git: URL = gitURL) -> Verdict {
        guard let inside = run(git, folder, ["rev-parse", "--is-inside-work-tree"]) else { return .unverifiable }
        if inside.status != 0 {
            // Only Git's own «not a repository» answer (status 128) means there is nothing to track the file.
            return inside.status == 128 && inside.error.contains("not a git repository") ? .allowed : .unverifiable
        }
        guard let ignored = run(git, folder, ["check-ignore", "-q", "--", name]) else { return .unverifiable }
        switch ignored.status {
        case 0: return .allowed
        case 1: return .notIgnored
        default: return .unverifiable
        }
    }

    /// Runs Git in `folder` with a clean environment; nil when the program could not be started.
    nonisolated private static func run(_ git: URL, _ folder: String, _ arguments: [String]) -> (status: Int32, error: String)? {
        let process = Process()
        process.executableURL = git
        process.arguments = ["-C", folder] + arguments
        process.environment = ["PATH": "/usr/bin:/bin", "GIT_OPTIONAL_LOCKS": "0", "LC_ALL": "C"]
        let errors = Pipe()
        process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        guard (try? process.run()) != nil else { return nil }
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
