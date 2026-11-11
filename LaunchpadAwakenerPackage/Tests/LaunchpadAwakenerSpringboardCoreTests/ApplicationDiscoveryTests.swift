import Foundation
import LaunchpadAwakenerSpringboardCore
import Testing
import Synchronization
import TestingSupport

@Suite("Finding applications")
struct ApplicationDiscoveryTests {
    @Test("applications in folders are found, applications inside bundles are not")
    func foldersAreSearchedButBundlesAreNot() throws {
        try withTemporaryDirectory { directoryURL in
            let searchDirectoryURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
            try ApplicationBundleFixture(name: "Alpha", bundleIdentifier: "com.example.alpha").write(in: searchDirectoryURL)
            try ApplicationBundleFixture(name: "Beta", bundleIdentifier: "com.example.beta")
                .write(in: searchDirectoryURL.appendingPathComponent("Vendor/Suite", isDirectory: true))
            let gammaURL = try ApplicationBundleFixture(name: "Gamma", bundleIdentifier: "com.example.gamma").write(in: searchDirectoryURL)
            try ApplicationBundleFixture(name: "Helper", bundleIdentifier: "com.example.gamma.helper")
                .write(in: gammaURL.appendingPathComponent("Contents/Applications", isDirectory: true))

            let discoveredApplications = ApplicationDiscovery.discoverApplications(in: [searchDirectoryURL], exclusionList: .standard)

            #expect(Set(discoveredApplications.map(\.bundleIdentifier)) == ["com.example.alpha", "com.example.beta", "com.example.gamma"])
        }
    }

    @Test("background-only applications are left out")
    func backgroundOnlyApplicationsAreLeftOut() throws {
        try withTemporaryDirectory { directoryURL in
            try ApplicationBundleFixture(name: "Agent", bundleIdentifier: "com.example.agent", isBackgroundOnly: true).write(in: directoryURL)
            try ApplicationBundleFixture(name: "Alpha", bundleIdentifier: "com.example.alpha").write(in: directoryURL)

            let discoveredApplications = ApplicationDiscovery.discoverApplications(in: [directoryURL], exclusionList: .standard)

            #expect(discoveredApplications.map(\.bundleIdentifier) == ["com.example.alpha"])
        }
    }

    @Test(
        "macOS 15's exclusion list and rules apply, and macOS 27's Apps launcher is excluded too",
        arguments: [
            ("Keychain Access", "com.apple.keychainaccess"),
            ("Setup", "com.example.setup"),
            ("Vendor Uninstaller", "com.example.uninstaller"),
            ("ExtendScript Toolkit", "com.adobe.estoolkit-4.0"),
            ("Contact Sheets", "com.example.contact-sheets"),
            ("Apps", "com.apple.apps.launcher"),
        ]
    )
    func exclusionListApplies(name: String, bundleIdentifier: String) {
        #expect(ApplicationExclusionList.standard.excludes(bundleIdentifier: bundleIdentifier, name: name))
    }

    @Test("an ordinary application is not excluded")
    func ordinaryApplicationIsNotExcluded() {
        #expect(!ApplicationExclusionList.standard.excludes(bundleIdentifier: "com.example.notes", name: "Notes"))
    }

    @Test("discovery leaves out what the exclusion list excludes")
    func discoveryAppliesTheExclusionList() throws {
        try withTemporaryDirectory { directoryURL in
            try ApplicationBundleFixture(name: "Vendor Uninstaller", bundleIdentifier: "com.example.uninstaller").write(in: directoryURL)
            try ApplicationBundleFixture(name: "Alpha", bundleIdentifier: "com.example.alpha").write(in: directoryURL)

            let discoveredApplications = ApplicationDiscovery.discoverApplications(in: [directoryURL], exclusionList: .standard)

            #expect(discoveredApplications.map(\.bundleIdentifier) == ["com.example.alpha"])
        }
    }

    /// The Dock runs for days. A bundle replaced in place must be read afresh, not from what the process
    /// cached the first time it looked at that path.
    @Test("a bundle replaced in place is read afresh")
    func replacedBundleIsReadAfresh() throws {
        try withTemporaryDirectory { directoryURL in
            try ApplicationBundleFixture(name: "Mos", bundleIdentifier: "com.example.mos").write(in: directoryURL)
            #expect(ApplicationDiscovery.discoverApplications(in: [directoryURL], exclusionList: .standard).map(\.bundleIdentifier) == ["com.example.mos"])

            try ApplicationBundleFixture(name: "Mos", bundleIdentifier: "com.example.mos.fork").write(in: directoryURL)

            #expect(ApplicationDiscovery.discoverApplications(in: [directoryURL], exclusionList: .standard).map(\.bundleIdentifier) == ["com.example.mos.fork"])
        }
    }

    @Test("an application reachable through a symbolic link is listed once")
    func symbolicLinksDoNotDuplicate() throws {
        try withTemporaryDirectory { directoryURL in
            let realDirectoryURL = directoryURL.appendingPathComponent("Cryptex", isDirectory: true)
            let linkingDirectoryURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
            let realBundleURL = try ApplicationBundleFixture(name: "Alpha", bundleIdentifier: "com.example.alpha").write(in: realDirectoryURL)
            try FileManager.default.createDirectory(at: linkingDirectoryURL, withIntermediateDirectories: true)
            let linkURL = linkingDirectoryURL.appendingPathComponent("Alpha.app")
            try FileManager.default.createSymbolicLink(at: linkURL, withDestinationURL: realBundleURL)

            let discoveredApplications = ApplicationDiscovery.discoverApplications(in: [linkingDirectoryURL, realDirectoryURL], exclusionList: .standard)

            #expect(discoveredApplications.map(\.url.lastPathComponent) == ["Alpha.app"])
            #expect(discoveredApplications.first?.url.deletingLastPathComponent().lastPathComponent == "Applications")
        }
    }

    @Test("the exclusion list is macOS 15.5's LaunchPadLayout.plist")
    func exclusionListMatchesMacOS15() throws {
        let plistURL = try #require(Bundle.module.url(forResource: "LaunchPadLayout", withExtension: "plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        let exclusion = try #require((plist["launchpad"] as? [String: Any])?["exclude"] as? [String: Any])
        let bundleIdentifiers = try #require(exclusion["bundleids"] as? [String])

        #expect(ApplicationExclusionList.macOS15.excludedIdentifiers == Set(bundleIdentifiers))
        #expect(ApplicationExclusionList.macOS15.rules == [
            .nameMatches("setup"),
            .bundleIdentifierHasPrefix("com.adobe.estoolkit"),
            .nameContains("uninstall"),
        ])
        #expect((exclusion["rules"] as? [[String: String]]) == [
            ["name": "setup", "type": "match"],
            ["type": "prefix", "bundleid": "com.adobe.estoolkit"],
            ["name": "uninstall", "type": "contains"],
        ])
    }

    @Test("the default first page is macOS 15.5's LaunchPadLayout.plist")
    func defaultFirstPageMatchesMacOS15() throws {
        let plistURL = try #require(Bundle.module.url(forResource: "LaunchPadLayout", withExtension: "plist"))
        let plist = try #require(try PropertyListSerialization.propertyList(from: Data(contentsOf: plistURL), format: nil) as? [String: Any])
        let layout = try #require((plist["launchpad"] as? [String: Any])?["layout"] as? [String: Any])
        let mainPage = try #require(layout["mainPage"] as? [[String: Any]])

        let entriesFromPlist = mainPage.map { entry -> DefaultLaunchpadLayout.Entry in
            if let contents = entry["contents"] as? [[String: String]] {
                return .folder(title: entry["title"] as? String ?? "", applicationBundleIdentifiers: contents.compactMap { $0["bundleid"] })
            }
            return .application(bundleIdentifier: entry["bundleid"] as? String ?? "")
        }
        #expect(DefaultLaunchpadLayout.mainPage == entriesFromPlist)
    }
    /// Enough discoveries at once to fill the Swift concurrency pool, which is how a hang
    /// underneath this one showed up.
    ///
    /// Describing a bundle asks `FileManager` for its display name, and for a bundle LaunchServices
    /// has not seen before that means registering it — a synchronous XPC call with no deadline of its
    /// own. Ten of those in flight from one process wedged this test bundle twice in three runs on
    /// 2026-11-11: the first few registrations answered, then every thread stopped inside
    /// `displayName(atPath:)` and none of them came back (74 and 42 minutes before they were killed,
    /// while the same lookup made from another process still answered in under a second). Serializing
    /// the lookup is what fixes it; this is the test that fails without it.
    ///
    /// Shaped to fail rather than to hang: the discoveries run on threads of their own and the test
    /// waits on a deadline instead of on them, so the deadlock coming back is a red test rather than a
    /// run that never ends.
    @Test("sixteen discoveries at once all finish")
    func concurrentDiscoveriesAllFinish() throws {
        let discoveryCount = 16
        let applicationsPerDiscovery = 4
        let roundCount = 3
        try withTemporaryDirectory { directoryURL in
            for round in 0 ..< roundCount {
                // A directory each, holding bundles LaunchServices has never seen: one it already knows
                // is answered out of its database, without the registration this test is about. Several
                // rounds because the deadlock is a race — one round caught it in one run out of three.
                let searchDirectoryURLs = try (0 ..< discoveryCount).map { discoveryIndex -> URL in
                    let searchDirectoryURL = directoryURL
                        .appendingPathComponent("Round-\(round)/Applications-\(discoveryIndex)", isDirectory: true)
                    for applicationIndex in 0 ..< applicationsPerDiscovery {
                        try ApplicationBundleFixture(
                            name: "Alpha \(round)-\(discoveryIndex)-\(applicationIndex)",
                            bundleIdentifier: "com.example.alpha-\(round)-\(discoveryIndex)-\(applicationIndex)"
                        ).write(in: searchDirectoryURL)
                    }
                    return searchDirectoryURL
                }

                let finishedDiscoveries = DispatchSemaphore(value: 0)
                let discoveredCounts = Mutex<[Int]>([])
                for searchDirectoryURL in searchDirectoryURLs {
                    // Tasks rather than threads of their own: the runs that hung had every thread of the
                    // Swift concurrency pool stopped inside this call, which is the state wanted here.
                    Task.detached {
                        let discoveredApplications = ApplicationDiscovery.discoverApplications(
                            in: [searchDirectoryURL],
                            exclusionList: .standard
                        )
                        discoveredCounts.withLock { $0.append(discoveredApplications.count) }
                        finishedDiscoveries.signal()
                    }
                }

                for _ in 0 ..< discoveryCount {
                    // A round takes about 1.5 seconds with the lookup serialized — registering a
                    // bundle is around 20 ms — so a 30-second deadline is the deadlock, not slowness.
                    guard finishedDiscoveries.wait(timeout: .now() + .seconds(30)) == .success else {
                        Issue.record("A discovery in round \(round) never came back — see this test's comment")
                        return
                    }
                }

                #expect(discoveredCounts.withLock { $0 } == Array(repeating: applicationsPerDiscovery, count: discoveryCount))
            }
        }
    }
}
