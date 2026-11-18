import Foundation

/// What the status bar says about the supervisor when its answer goes missing. A restart, a Mac
/// waking up or one slow answer must not flash «Detenido»: after an answer was seen, a missing one
/// reads «Reconectando…» for `grace` seconds and only then «Detenido». A Mac that has just woken
/// starts the grace again, since the read that failed may have crossed the sleep.
struct DaemonLiveness: Equatable {
    static let grace: TimeInterval = 5

    enum Phase: Equatable { case running, reconnecting, stopped }

    /// The last read found the supervisor.
    private(set) var up = false
    /// An answer was seen since the app started; before that there is nothing to reconnect to.
    private var seenUp = false
    private var lostAt: Date?
    private var wokeAt: Date?

    /// One read of the supervisor's state.
    mutating func observe(up now: Bool, at date: Date) {
        up = now
        if now {
            seenUp = true
            lostAt = nil
        } else if lostAt == nil {
            lostAt = date
        }
    }

    /// The Mac woke up (`NSWorkspace.didWakeNotification`).
    mutating func wake(at date: Date) { wokeAt = date }

    func phase(at date: Date) -> Phase {
        if up { return .running }
        return remaining(at: date) == nil ? .stopped : .reconnecting
    }

    /// Seconds left of the grace; nil when it is over or never applied.
    func remaining(at date: Date) -> TimeInterval? {
        guard !up, seenUp, let lostAt else { return nil }
        let start = max(lostAt, wokeAt ?? .distantPast)
        let left = Self.grace - date.timeIntervalSince(start)
        return left > 0 ? left : nil
    }
}
