import Foundation
import Darwin

/// Sends `SIGTERM`, as `killall` does, and says what came of it.
enum ProcessTermination: Equatable {
    case terminated
    /// The process belongs to someone else — another user's Dock under fast user switching. Not this
    /// user's to restart, and not an error.
    case belongsToAnotherUser
    case alreadyGone
    case failed(reason: String)

    static func terminate(_ processIdentifier: pid_t) -> ProcessTermination {
        // `kill` reads 0 and negative values as process groups.
        guard processIdentifier > 0 else { return .failed(reason: "\(processIdentifier) is not a process") }
        guard kill(processIdentifier, SIGTERM) != 0 else { return .terminated }
        switch errno {
        case EPERM:
            return .belongsToAnotherUser
        case ESRCH:
            return .alreadyGone
        case let errorNumber:
            return .failed(reason: String(cString: strerror(errorNumber)))
        }
    }
}
