import Foundation
import Synchronization
import XPC

/// Values a handler on an XPC queue hands to the test, behind a lock.
public final class Recorder<Element: Sendable>: Sendable {
    private let elements = Mutex<[Element]>([])

    public init() {}

    public func append(_ element: Element) {
        elements.withLock { $0.append(element) }
    }

    public var recorded: [Element] {
        elements.withLock { $0 }
    }
}

/// Sends `message` over `session` and waits for the reply, decoded as `Reply`.
public func sendExpectingReply<Message: Encodable, Reply: Decodable & Sendable>(
    _ message: Message,
    over session: XPCSession,
    as replyType: Reply.Type = Reply.self,
    isolation: isolated (any Actor)? = #isolation
) async throws -> Reply {
    try await withCheckedThrowingContinuation { continuation in
        do {
            try session.send(message) { (result: Result<Reply, any Error>) in
                continuation.resume(with: result)
            }
        } catch {
            continuation.resume(throwing: error)
        }
    }
}

/// Polls `condition` on the main actor until it holds or `timeout` runs out. XPC delivers on its own queues,
/// so a test that waits for something it cannot await — a cancellation, a one-way message — waits this way.
@MainActor
public func waitUntil(timeout: Duration = .seconds(5), _ condition: @MainActor () -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() {
            return true
        }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}
