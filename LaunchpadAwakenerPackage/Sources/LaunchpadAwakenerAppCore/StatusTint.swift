import ServiceManagement

/// What a status reads as at a glance: the colour of the banner, of a status dot, of a line of text.
///
/// A role rather than a colour, so that the app core decides what a state means and the interface
/// decides how that looks.
public enum StatusTint: Sendable, Equatable {
    /// Something is under way.
    case progress
    /// Working as intended.
    case positive
    /// Waiting for a step from the user, or working with a caveat.
    case caution
    /// Not working, and waiting will not change that.
    case critical
    /// Switched off on purpose by the user.
    case paused
    /// Not set up, or nothing to report yet.
    case neutral
}

extension StatusTint {
    /// How a login item's registration reads: enabled is positive, waiting for approval needs the
    /// user, missing from the bundle is broken, and anything else is not set up.
    public init(_ registrationStatus: SMAppService.Status) {
        switch registrationStatus {
        case .enabled:
            self = .positive
        case .requiresApproval:
            self = .caution
        case .notFound:
            self = .critical
        default:
            self = .neutral
        }
    }
}
