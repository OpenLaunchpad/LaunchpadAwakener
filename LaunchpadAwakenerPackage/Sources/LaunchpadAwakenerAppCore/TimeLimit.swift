import Foundation
import Synchronization

/// Thrown by ``withTimeLimit(_:operation:)`` when the operation did not finish in time.
struct TimeLimitExceededError: LocalizedError {
    let timeLimit: Duration

    var errorDescription: String? {
        "No answer within \(timeLimit.formatted(.units(allowed: [.seconds, .milliseconds], width: .wide)))."
    }
}

/// Runs `operation`, giving up after `timeLimit`; whichever finishes first decides, and the other is
/// cancelled and not waited for.
///
/// Not a task group. A group returns only once every child has finished, so it can neither return
/// before a losing timer runs out unless the timer cooperates, nor abandon an operation that ignores
/// cancellation — and an XPC request the other side never answers is exactly such an operation.
/// The payload channel's handshake wait used to race two tasks inside a group and, because the
/// group awaited the losing timer, reported every injection five seconds after the payload answered.
func withTimeLimit<Value: Sendable>(
    _ timeLimit: Duration,
    operation: @escaping @Sendable () async throws -> Value
) async throws -> Value {
    let race = TimeLimitRace<Value>()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            race.install(continuation)
            let work = Task {
                do {
                    race.finish(.success(try await operation()))
                } catch {
                    race.finish(.failure(error))
                }
            }
            let timer = Task {
                // Cancelled when the work wins; finishing then is a no-op, the race is decided.
                try? await Task.sleep(for: timeLimit)
                race.finish(.failure(TimeLimitExceededError(timeLimit: timeLimit)))
            }
            race.adopt([work, timer])
        }
    } onCancel: {
        race.finish(.failure(CancellationError()))
    }
}

/// The shared state of one ``withTimeLimit(_:operation:)`` call: the first result wins, resumes the
/// caller and cancels the rest.
private final class TimeLimitRace<Value: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<Value, any Error>?
        var result: Result<Value, any Error>?
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    /// Cancellation can arrive before the continuation exists; a result that is already in is then
    /// delivered at once.
    func install(_ continuation: CheckedContinuation<Value, any Error>) {
        let decidedResult = state.withLock { state -> Result<Value, any Error>? in
            guard let result = state.result else {
                state.continuation = continuation
                return nil
            }
            return result
        }
        if let decidedResult {
            continuation.resume(with: decidedResult)
        }
    }

    func adopt(_ tasks: [Task<Void, Never>]) {
        let isDecided = state.withLock { state -> Bool in
            guard state.result == nil else { return true }
            state.tasks = tasks
            return false
        }
        if isDecided { tasks.forEach { $0.cancel() } }
    }

    func finish(_ result: Result<Value, any Error>) {
        let decision = state.withLock { state -> (CheckedContinuation<Value, any Error>?, [Task<Void, Never>])? in
            guard state.result == nil else { return nil }
            state.result = result
            defer {
                state.continuation = nil
                state.tasks = []
            }
            return (state.continuation, state.tasks)
        }
        guard let (continuation, tasks) = decision else { return }
        continuation?.resume(with: result)
        tasks.forEach { $0.cancel() }
    }
}
