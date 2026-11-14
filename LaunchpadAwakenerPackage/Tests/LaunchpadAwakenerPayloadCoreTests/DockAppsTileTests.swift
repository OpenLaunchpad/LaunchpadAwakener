import Foundation
@testable import LaunchpadAwakenerPayloadCore
import Testing
import TestingSupport

/// Which tile in the Dock gets the Launchpad icon.
///
/// The Dock has no notion of "the Apps tile" — Apps is an ordinary application tile — so this is decided
/// from the bundle the tile stands for. Reaching a tile needs a Dock, but the rule for deciding does not,
/// which is why `isAppsBundle(at:)` is where these ask their questions.
@Suite("The Dock's Apps tile")
struct DockAppsTileTests {
    @Test("a bundle with the system Apps' identifier is the Apps tile, wherever it sits")
    func recognisesAppsByItsIdentifier() throws {
        try withTemporaryDirectory { directoryURL in
            let bundleURL = try ApplicationBundleFixture(
                name: "Apps",
                bundleIdentifier: "com.apple.apps.launcher"
            ).write(in: directoryURL)

            #expect(DockAppsTile.isAppsBundle(at: bundleURL))
        }
    }

    @Test("another application is not the Apps tile")
    func doesNotMistakeAnotherApplicationForApps() throws {
        try withTemporaryDirectory { directoryURL in
            let bundleURL = try ApplicationBundleFixture(
                name: "Chess",
                bundleIdentifier: "com.apple.Chess"
            ).write(in: directoryURL)

            #expect(!DockAppsTile.isAppsBundle(at: bundleURL))
        }
    }

    @Test("the system's Apps is recognised from its path alone")
    func recognisesAppsByItsPath() {
        // The path is compared before the bundle is opened, which is what keeps the Dock's rendering path
        // off the disk for every tile that is not Apps. Deliberately not asserted against the machine's own
        // /System/Applications/Apps.app: this has to hold on a machine that has none.
        #expect(DockAppsTile.isAppsBundle(at: URL(fileURLWithPath: "/System/Applications/Apps.app")))
    }

    @Test("the answer outlives the bundle, so the Dock's rendering path reads it once")
    func remembersTheAnswer() throws {
        try withTemporaryDirectory { directoryURL in
            let bundleURL = try ApplicationBundleFixture(
                name: "Apps",
                bundleIdentifier: "com.apple.apps.launcher"
            ).write(in: directoryURL)
            #expect(DockAppsTile.isAppsBundle(at: bundleURL))

            try FileManager.default.removeItem(at: bundleURL)

            #expect(
                DockAppsTile.isAppsBundle(at: bundleURL),
                "the second answer has to come from the cache: reading the bundle again would now fail"
            )
        }
    }

    @Test("the same bundle spelled differently is the same bundle")
    func normalisesThePath() throws {
        try withTemporaryDirectory { directoryURL in
            let bundleURL = try ApplicationBundleFixture(
                name: "Apps",
                bundleIdentifier: "com.apple.apps.launcher"
            ).write(in: directoryURL)
            #expect(DockAppsTile.isAppsBundle(at: bundleURL))

            try FileManager.default.removeItem(at: bundleURL)
            let spelledWithADetour = directoryURL
                .appendingPathComponent("Apps.app", isDirectory: true)
                .appendingPathComponent("..", isDirectory: true)
                .appendingPathComponent("Apps.app", isDirectory: true)

            #expect(
                DockAppsTile.isAppsBundle(at: spelledWithADetour),
                "a detour through .. is the same bundle, and so reaches the same cached answer"
            )
        }
    }
}
