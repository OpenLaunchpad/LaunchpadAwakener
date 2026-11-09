import Foundation
import Darwin

/// Whether a process still exists.
///
/// Used by ``PayloadInjectionCoordinator/refreshState()`` to drop hosts that have gone away. That
/// clean-up used to depend entirely on the process monitor's exit sources, which only exist while
/// the monitor is running — so with automatic re-injection switched off, a restarted Dock left its
/// old process identifier on display indefinitely.
enum ProcessLiveness {
    /// Checked with `kill` and signal 0, which runs the existence and permission checks without
    /// delivering anything.
    ///
    /// `EPERM` counts as alive: it means the process is there and belongs to somebody else. The
    /// question being asked is whether it still exists, not whether this app may signal it.
    static func isAlive(_ processIdentifier: pid_t) -> Bool {
        // A non-positive identifier is not a process. `kill` would read 0 as "every process in the
        // caller's group" and negatives as a process group, either of which would answer a question
        // nobody asked.
        guard processIdentifier > 0 else { return false }
        guard kill(processIdentifier, 0) != 0 else { return true }
        return errno == EPERM
    }
}
