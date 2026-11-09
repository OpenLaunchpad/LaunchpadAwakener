import Foundation
import Testing
@testable import LaunchpadAwakenerAppCore

/// Covers the guard that switches automatic injection off when the payload keeps bringing the Dock
/// down, and the rule that a deliberate restart is not one of those times.
///
/// `recordExit` results are bound to a variable before being asserted on: `#expect` decomposes its
/// expression into a closure over the operands, which cannot call a `mutating` member.
@Suite("Quick-exit guard")
struct QuickExitGuardTests {
    private static let referenceTime = Date(timeIntervalSince1970: 1_000_000)

    @Test("Three quick exits in a row reach the limit")
    func threeQuickExitsReachTheLimit() {
        var exitGuard = QuickExitGuard(quickExitInterval: 15, limit: 3)
        var reachedLimit: [Bool] = []
        for (index, processIdentifier) in [pid_t(101), 102, 103].enumerated() {
            let injectionTime = Self.referenceTime.addingTimeInterval(Double(index) * 20)
            exitGuard.recordInjection(of: processIdentifier, at: injectionTime)
            reachedLimit.append(exitGuard.recordExit(of: processIdentifier, at: injectionTime.addingTimeInterval(2)))
        }
        #expect(reachedLimit == [false, false, true])
    }

    @Test("An exit after the interval breaks the run")
    func slowExitBreaksTheRun() {
        var exitGuard = QuickExitGuard(quickExitInterval: 15, limit: 3)

        exitGuard.recordInjection(of: 101, at: Self.referenceTime)
        _ = exitGuard.recordExit(of: 101, at: Self.referenceTime.addingTimeInterval(1))
        exitGuard.recordInjection(of: 102, at: Self.referenceTime)
        _ = exitGuard.recordExit(of: 102, at: Self.referenceTime.addingTimeInterval(1))
        #expect(exitGuard.consecutiveQuickExitCount == 2)

        exitGuard.recordInjection(of: 103, at: Self.referenceTime)
        let reachedLimit = exitGuard.recordExit(of: 103, at: Self.referenceTime.addingTimeInterval(60))
        #expect(!reachedLimit)
        #expect(exitGuard.consecutiveQuickExitCount == 0)
    }

    /// The reason ``QuickExitGuard/forget(_:)`` exists: the Dock restarted from the app's own button
    /// exits seconds after being injected, every time. Counted, three presses would switch automatic
    /// injection off for a payload that is working perfectly.
    @Test("A forgotten Dock's exit is not counted")
    func forgottenExitIsNotCounted() {
        var exitGuard = QuickExitGuard(quickExitInterval: 15, limit: 3)
        var reachedLimit = false
        for processIdentifier in [pid_t(101), 102, 103, 104] {
            exitGuard.recordInjection(of: processIdentifier, at: Self.referenceTime)
            exitGuard.forget(processIdentifier)
            reachedLimit = exitGuard.recordExit(of: processIdentifier, at: Self.referenceTime.addingTimeInterval(1))
            #expect(!reachedLimit)
        }
        #expect(exitGuard.consecutiveQuickExitCount == 0)
    }

    @Test("A Dock that was never injected says nothing about the payload")
    func uninjectedExitIsIgnored() {
        var exitGuard = QuickExitGuard(quickExitInterval: 15, limit: 1)
        let reachedLimit = exitGuard.recordExit(of: 101, at: Self.referenceTime)
        #expect(!reachedLimit)
        #expect(exitGuard.consecutiveQuickExitCount == 0)
    }

    @Test("Resetting starts the count afresh")
    func resetStartsAfresh() {
        var exitGuard = QuickExitGuard(quickExitInterval: 15, limit: 3)
        exitGuard.recordInjection(of: 101, at: Self.referenceTime)
        _ = exitGuard.recordExit(of: 101, at: Self.referenceTime.addingTimeInterval(1))
        exitGuard.reset()
        #expect(exitGuard.consecutiveQuickExitCount == 0)
    }
}
