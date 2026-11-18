import Foundation

/// What a page reads that can fail on its own (E-07): each has its line on the pages that show it.
enum ReadArea: String, Hashable, Sendable, CaseIterable {
    /// Installed versions of languages and services (Lenguajes, Servicios).
    case runtimes
    /// The mail catcher's inbox (Correo).
    case mail

    /// Written whole: the engine's test of error texts finds the keys the app names itself.
    var titleKey: String {
        switch self {
        case .runtimes: "error.read.runtimes"
        case .mail: "error.read.mail"
        }
    }
}

/// One failure of this session, kept (a few) for the problem report. The engine's own detail may hold a
/// path or a value: it is cleaned (`ProblemReport.redact`) when the report is built, never before.
struct FailureRecord: Sendable, Equatable {
    var date: Date
    var title: String
    var message: String
    var code: String?
    var technical: String?
}

extension StackStore {
    static let recentFailureLimit = 20
    /// Reads that failed this many times in a row are said; one blip of a poll is not.
    static let readFailureStreak = 2

    func record(_ failure: ActionFailure, at date: Date = Date()) {
        recentFailures.append(FailureRecord(date: date, title: failure.title, message: failure.message,
                                            code: failure.code, technical: failure.technical))
        if recentFailures.count > Self.recentFailureLimit { recentFailures.removeFirst(recentFailures.count - Self.recentFailureLimit) }
    }

    /// Closes a read of `area`: a failure becomes the line of its page (with «Reintentar»), a success clears it.
    /// `streak` is how many failures in a row it takes to say it: 1 for a read the user asked for (the page
    /// opening), more for a read that repeats by itself, so a blip of the engine does not flash a notice.
    func readDone(_ area: ReadArea, _ error: Error?, streak: Int = 1, retry: (@MainActor () async -> Void)?) {
        guard let error else {
            readFailureCounts[area] = nil
            if pageFailures[area] != nil { pageFailures[area] = nil }
            return
        }
        let count = (readFailureCounts[area] ?? 0) + 1
        readFailureCounts[area] = count
        guard count >= streak else { return }
        let failure = ActionFailure(error: error, title: L(area.titleKey), impact: .partial, retry: retry)
        // The same failure again (a poll) is not recorded twice.
        if pageFailures[area]?.message != failure.message { record(failure) }
        pageFailures[area] = failure
    }
}
