import Foundation
@testable import LaunchpadAwakenerUpdating
import Testing

/// Which feed a build checks: a release build the one its Info.plist names, a development build none
/// unless launched with `-UpdateFeedURL <url>`, so that it never reads the feed the shipped app reads.
@Suite("The feed a build checks for updates")
struct UpdateFeedResolutionTests {
    private static let releaseFeed = "https://github.com/OpenLaunchpad/LaunchpadAwakener/releases/latest/download/LaunchpadAwakenerAppcast.xml"
    private static let testingFeed = "http://127.0.0.1:8765/LaunchpadAwakenerAppcast.xml"

    @Test("a release build uses the feed its Info.plist names")
    func releaseBuildUsesTheBundledFeed() {
        let feedURL = UpdateFeedResolution.feedURL(infoDictionaryValue: Self.releaseFeed, overrideValue: nil, allowsOverride: false)
        #expect(feedURL == URL(string: Self.releaseFeed))
    }

    @Test("a development build launched without an override has no feed")
    func developmentBuildWithoutOverrideHasNoFeed() {
        let feedURL = UpdateFeedResolution.feedURL(infoDictionaryValue: "", overrideValue: nil, allowsOverride: true)
        #expect(feedURL == nil)
    }

    @Test("a development build uses the feed it was launched with")
    func developmentBuildUsesTheOverrideFeed() {
        let feedURL = UpdateFeedResolution.feedURL(infoDictionaryValue: "", overrideValue: Self.testingFeed, allowsOverride: true)
        #expect(feedURL == URL(string: Self.testingFeed))
    }

    @Test("a release build ignores a feed given at launch")
    func releaseBuildIgnoresTheOverride() {
        let feedURL = UpdateFeedResolution.feedURL(infoDictionaryValue: Self.releaseFeed, overrideValue: Self.testingFeed, allowsOverride: false)
        #expect(feedURL == URL(string: Self.releaseFeed))
    }

    @Test("an empty or blank feed counts as none", arguments: [nil, "", "   "] as [String?])
    func emptyFeedValueCountsAsNone(value: String?) {
        #expect(UpdateFeedResolution.feedURL(infoDictionaryValue: value, overrideValue: value, allowsOverride: true) == nil)
        #expect(UpdateFeedResolution.feedURL(infoDictionaryValue: value, overrideValue: value, allowsOverride: false) == nil)
    }
}
