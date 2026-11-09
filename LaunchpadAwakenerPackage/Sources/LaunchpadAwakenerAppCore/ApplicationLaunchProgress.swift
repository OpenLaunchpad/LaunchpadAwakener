import Foundation

/// How far the app got through its launch sequence, and what stopped it if anything did.
///
/// Exists because the launch sequence used to fail silently. Every step that could not proceed
/// returned early — no error recorded, no status shown — so a launch that reached nothing looked
/// exactly like a launch that had nothing to do. In DockIconOverride, on 2026-08-11, that produced a login-item launch
/// which failed to reach the daemon at 20:22 and then sat idle for four minutes with a window that
/// gave no indication anything had gone wrong.
///
/// Recovery is deliberately *not* driven from here. The process monitor's discovery pass retries
/// injection on its own schedule and every injection makes the daemon usable first, so a launch
/// that could not finish is a fact to report rather than a loop to run. This says where things got
/// to; it does not decide what happens next.
@Observable
@MainActor
public final class ApplicationLaunchProgress {
    public enum Phase: Sendable, Equatable {
        /// Nothing has run yet.
        case notStarted
        /// Checking that the daemon is reachable and current, reinstalling it if not.
        case preparingDaemon
        /// Looking for payloads left resident by an earlier session.
        case reconnectingToPayloads
        /// Injecting into targets that are already running.
        case injecting
        /// Everything the launch could do is done.
        case ready
        /// The launch stopped early. Automatic retries may still recover it.
        case stopped(reason: String)

        /// One line suitable for display, or nil when there is nothing worth saying.
        public var progressDescription: String? {
            switch self {
            case .notStarted, .ready:
                return nil
            case .preparingDaemon:
                return "Checking the privileged daemon…"
            case .reconnectingToPayloads:
                return "Looking for payloads already in place…"
            case .injecting:
                return "Injecting into the Dock…"
            case .stopped(let reason):
                return reason
            }
        }

        public var isInProgress: Bool {
            switch self {
            case .preparingDaemon, .reconnectingToPayloads, .injecting:
                return true
            case .notStarted, .ready, .stopped:
                return false
            }
        }
    }

    public private(set) var phase: Phase = .notStarted

    public init() {}

    public func enter(_ phase: Phase) {
        self.phase = phase
    }
}
