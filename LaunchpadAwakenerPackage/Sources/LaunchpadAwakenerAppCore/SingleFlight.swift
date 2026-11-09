import Foundation

/// Runs an operation at most once at a time; callers that arrive while it runs wait for that run and
/// get its result instead of starting their own.
///
/// At launch the launch sequence, the monitor's first sight of the Dock and its first discovery pass
/// all ask for the same things within milliseconds of each other — "is the daemon usable", "which
/// payloads are already in place". Run separately, the first daemon check reinstalls the daemon and
/// the others are refused by the reinstall cooldown and report a failure for a daemon that is fine.
@MainActor
final class SingleFlight<Value: Sendable> {
    private var inFlight: Task<Value, Never>?

    func run(_ operation: @escaping @MainActor () async -> Value) async -> Value {
        if let inFlight {
            return await inFlight.value
        }
        let task = Task { await operation() }
        inFlight = task
        let value = await task.value
        inFlight = nil
        return value
    }
}
