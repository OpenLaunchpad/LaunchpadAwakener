import Foundation

/// Which feed a build checks for updates.
///
/// A release build reads the feed its Info.plist names (`SUFeedURL`, filled in from the `UPDATE_FEED_URL`
/// build setting). A development build has an empty one, so that it never offers the shipped app as an
/// update of itself; on the test machine it is launched with `-UpdateFeedURL <url>` instead, a feed served
/// there for the occasion.
public enum UpdateFeedResolution {
    /// The defaults key a development build reads its feed from. A launch argument `-UpdateFeedURL <url>`
    /// sets it for that launch only.
    public static let overrideDefaultsKey = "UpdateFeedURL"

    /// Whether this build may be pointed at another feed: only a development build.
    public static let allowsOverride: Bool = {
        #if DEBUG
        true
        #else
        false
        #endif
    }()

    /// The feed to check, or nil when there is none, and the updater should not start.
    ///
    /// - Parameters:
    ///   - infoDictionaryValue: The Info.plist's `SUFeedURL`.
    ///   - overrideValue: The feed given at launch, under ``overrideDefaultsKey``.
    ///   - allowsOverride: Whether the build may use `overrideValue`; see ``allowsOverride``.
    public static func feedURL(infoDictionaryValue: String?, overrideValue: String?, allowsOverride: Bool) -> URL? {
        if allowsOverride, let overrideURL = url(from: overrideValue) {
            return overrideURL
        }
        return url(from: infoDictionaryValue)
    }

    /// The feed of the running app: its Info.plist's, or in a development build the one given at launch.
    public static func feedURL(of bundle: Bundle, defaults: UserDefaults) -> URL? {
        feedURL(
            infoDictionaryValue: bundle.object(forInfoDictionaryKey: "SUFeedURL") as? String,
            overrideValue: defaults.string(forKey: overrideDefaultsKey),
            allowsOverride: allowsOverride
        )
    }

    private static func url(from value: String?) -> URL? {
        guard let trimmedValue = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmedValue.isEmpty else {
            return nil
        }
        return URL(string: trimmedValue)
    }
}
