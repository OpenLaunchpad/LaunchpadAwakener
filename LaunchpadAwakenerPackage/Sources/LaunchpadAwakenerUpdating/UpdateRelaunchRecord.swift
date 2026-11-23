import Foundation

/// Whether this launch is Sparkle reopening the app to finish an update, rather than the user opening it.
///
/// Sparkle tells the app it is about to relaunch it (`updaterWillRelaunchApplication(_:)`), and nothing at
/// the next launch says why it happened. So the old process notes it in the defaults, and the new one takes
/// the note at launch: the standalone app then does not cover the screen, and the injected app keeps its
/// control panel closed, as after a launch at login.
public struct UpdateRelaunchRecord {
    static let defaultsKey = "RelaunchedToFinishAnUpdate"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Notes that Sparkle is about to relaunch the app.
    public func noteRelaunch() {
        defaults.set(true, forKey: Self.defaultsKey)
    }

    /// Whether Sparkle relaunched the app to finish an update. Reading it clears it, so only the launch
    /// right after the update counts.
    public func takeRelaunchNote() -> Bool {
        let wasRelaunched = defaults.bool(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.defaultsKey)
        return wasRelaunched
    }
}
