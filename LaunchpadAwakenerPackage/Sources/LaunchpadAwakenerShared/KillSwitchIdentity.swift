import Foundation

/// The kill switch: a file whose presence sends every "open Apps" entry back to the system's Apps.
///
/// Shared by the springboard, which checks it before showing, and the app, whose window offers it as
/// a switch. A file rather than a preference so that it can be set from a terminal or over ssh while
/// the screen is unusable — the reason it exists. It lives in `/tmp`, so a restart clears it.
public enum KillSwitchIdentity {
    public static let path = "/tmp/LaunchpadAwakener.disabled"
}
