import Foundation

/// The build of this app launched last, to tell the first launch of a new one: after Sparkle installed an
/// update, or the user put a newer copy in place by hand.
public struct LaunchedBuildRecord {
    static let defaultsKey = "LastLaunchedBuild"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Records `build` as launched, and returns whether it differs from the build launched before, or no
    /// launch was recorded yet — as for a copy updated from a version that did not record its launches.
    @discardableResult
    public func recordLaunch(ofBuild build: String) -> Bool {
        let previousBuild = defaults.string(forKey: Self.defaultsKey)
        defaults.set(build, forKey: Self.defaultsKey)
        return previousBuild != build
    }
}
