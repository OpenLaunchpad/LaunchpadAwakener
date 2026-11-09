import Foundation

/// Notices a payload that brings the Dock down as it loads, so automatic injection stops feeding it
/// one Dock after another.
///
/// With automatic injection on, a payload that crashes the Dock is injected into every Dock launchd
/// starts in its place, indefinitely. A Dock that exits within ``quickExitInterval`` of being injected
/// counts as brought down by the payload; ``limit`` of those in a row and the caller switches
/// automatic injection off.
///
/// A Dock the user restarts on purpose is forgotten before it exits (``forget(_:)``), so restarting
/// it from the app a few times in quick succession is not mistaken for a crash loop.
struct QuickExitGuard: Sendable, Equatable {
    let quickExitInterval: TimeInterval
    let limit: Int

    private var injectionDatesByProcessIdentifier: [pid_t: Date] = [:]
    private(set) var consecutiveQuickExitCount = 0

    init(quickExitInterval: TimeInterval = 15, limit: Int = 3) {
        self.quickExitInterval = quickExitInterval
        self.limit = limit
    }

    mutating func recordInjection(of processIdentifier: pid_t, at injectionDate: Date) {
        injectionDatesByProcessIdentifier[processIdentifier] = injectionDate
    }

    /// Drops a process without counting its exit, for a Dock that is being restarted deliberately.
    mutating func forget(_ processIdentifier: pid_t) {
        injectionDatesByProcessIdentifier.removeValue(forKey: processIdentifier)
    }

    /// Records an exit and returns whether it completes a run of ``limit`` quick exits.
    ///
    /// Only exits of processes this guard saw injected count either way: a Dock that was never
    /// injected says nothing about the payload.
    mutating func recordExit(of processIdentifier: pid_t, at exitDate: Date) -> Bool {
        guard let injectionDate = injectionDatesByProcessIdentifier.removeValue(forKey: processIdentifier) else {
            return false
        }
        if exitDate.timeIntervalSince(injectionDate) < quickExitInterval {
            consecutiveQuickExitCount += 1
        } else {
            consecutiveQuickExitCount = 0
        }
        return consecutiveQuickExitCount >= limit
    }

    /// Starts counting afresh, for when automatic injection is switched back on.
    mutating func reset() {
        consecutiveQuickExitCount = 0
    }
}
