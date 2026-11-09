import Foundation
import Testing
@testable import LaunchpadAwakenerAppCore

/// Covers the time limit put on every wait for the payload: its handshake after injection, and each
/// status request.
@Suite("Time limit")
struct TimeLimitTests {
    /// The regression: the wait for the payload's handshake raced two unstructured tasks from inside
    /// a task group. Cancelling the group does not cancel tasks it merely awaits, so the group waited
    /// for the losing timer every time — each injection's result appeared five seconds after the
    /// payload had already answered (11:24:20.657 injected, 11:24:25.990 reported, on the test Mac).
    @Test("An operation that finishes early returns at once, not when the limit runs out", .timeLimit(.minutes(1)))
    func earlyFinishReturnsAtOnce() async throws {
        let clock = ContinuousClock()
        let start = clock.now

        let value = try await withTimeLimit(.seconds(5)) { 42 }

        #expect(value == 42)
        #expect(clock.now - start < .seconds(1))
    }

    /// An XPC request that is never answered does not stop when its task is cancelled. The limit has to
    /// hold anyway, or one hung Dock stalls the window's refresh loop for good.
    @Test("An operation that ignores cancellation is still abandoned at the limit", .timeLimit(.minutes(1)))
    func uncooperativeOperationIsAbandoned() async {
        let clock = ContinuousClock()
        let start = clock.now

        await #expect(throws: TimeLimitExceededError.self) {
            try await withTimeLimit(.milliseconds(200)) {
                await Self.sleepIgnoringCancellation(for: 3)
                return 0
            }
        }
        #expect(clock.now - start < .seconds(2))
    }

    @Test("An operation's own error comes through", .timeLimit(.minutes(1)))
    func operationErrorComesThrough() async {
        struct ExpectedFailure: Error {}

        await #expect(throws: ExpectedFailure.self) {
            try await withTimeLimit(.seconds(5)) { () async throws -> Int in throw ExpectedFailure() }
        }
    }

    /// Stands in for an XPC send the other side never answers: resumed by a timer, deaf to cancellation.
    private static func sleepIgnoringCancellation(for seconds: Double) async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume()
            }
        }
    }
}
