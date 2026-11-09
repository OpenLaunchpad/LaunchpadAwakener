import Foundation

/// Rate-limits an expensive repair so that a failure which persists cannot trigger it repeatedly.
///
/// Extracted rather than left as a pair of fields on ``PrivilegedDaemonController`` because it
/// carries the load-bearing half of a decision DockIconOverride made after a broken daemon. Reinstalling
/// the daemon used to be gated on *classifying the error* — only "the daemon answered with the wrong
/// version" qualified, and every connection failure was dismissed as transient. That classification
/// was what made the repair unreachable in the one case that needed it: a launchd job that does not
/// start cannot answer, so it could never be found stale, so it was never reinstalled.
///
/// Gating on *how recently the repair was tried* instead covers both cases with one rule. A
/// momentary hiccup still cannot cause repeated reinstalls, which was the original concern, and a
/// daemon that is genuinely broken still gets repaired, which the old rule could not do.
struct RepairCooldown: Sendable, Equatable {
    /// Minimum time between attempts.
    let interval: TimeInterval

    /// When the last attempt was made, successful or not. Nil until the first one.
    ///
    /// Attempts are recorded rather than failures: a repair that appears to succeed but does not
    /// actually fix anything would otherwise be retried without limit.
    private(set) var lastAttempt: Date?

    init(interval: TimeInterval, lastAttempt: Date? = nil) {
        self.interval = interval
        self.lastAttempt = lastAttempt
    }

    /// Whether a repair may be attempted at `time`.
    func permitsAttempt(at time: Date) -> Bool {
        guard let lastAttempt else { return true }
        return time.timeIntervalSince(lastAttempt) >= interval
    }

    /// The earliest time another attempt is allowed, or nil if one is allowed now.
    func nextPermittedAttempt(after time: Date) -> Date? {
        guard let lastAttempt, !permitsAttempt(at: time) else { return nil }
        return lastAttempt.addingTimeInterval(interval)
    }

    /// Records an attempt at `time` if the cooldown allows one. Returns whether it did.
    mutating func recordAttempt(at time: Date) -> Bool {
        guard permitsAttempt(at: time) else { return false }
        lastAttempt = time
        return true
    }

    /// Forgets the last attempt, so the next one is permitted immediately.
    ///
    /// For when the reason to wait no longer applies — the user asked for something directly, or the
    /// thing being repaired was deliberately replaced.
    mutating func reset() {
        lastAttempt = nil
    }
}
