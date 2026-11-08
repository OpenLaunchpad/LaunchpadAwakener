import Foundation
import LaunchpadAwakenerPayloadCore
import Testing
import TestingSupport

/// macOS 15 marked an application downloaded from the App Store as recently added — bit 0x400 of
/// `items.flags` (`-[LPRunnable recentlyAdded]`, 15.5 `0x10001DCAC`) — and cleared the mark on every
/// item of that application once it was launched (`-[LPSpringboard markAppAsLaunched:]`, `0x1000B0CF8`).
@Suite("Recently added applications")
struct RecentlyAddedApplicationTests {
    @Test("bit 0x400 of an application's flags shows as recently added")
    func flagShows() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))
            let pageIdentifier = try store.appendPage(to: store.rootIdentifier)
            try store.appendApplication(LaunchpadApplicationRecord(title: "Alpha", bundleIdentifier: "com.example.alpha", itemFlags: 0x400), to: pageIdentifier)
            try store.appendApplication(LaunchpadApplicationRecord(title: "Beta", bundleIdentifier: "com.example.beta", itemFlags: 0x10), to: pageIdentifier)

            #expect(try store.layout().applications.map(\.isRecentlyAdded) == [true, false])
        }
    }

    @Test("launching clears the mark on every item of the application, once")
    func launchingClearsTheMark() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))
            let pageIdentifier = try store.appendPage(to: store.rootIdentifier)
            try store.appendApplication(LaunchpadApplicationRecord(title: "Alpha", bundleIdentifier: "com.example.alpha", itemFlags: 0x400 | 0x10), to: pageIdentifier)
            let folder = try store.appendFolder(titled: "Tools", to: pageIdentifier)
            try store.appendApplication(LaunchpadApplicationRecord(title: "Alpha", bundleIdentifier: "com.example.alpha", itemFlags: 0x400), to: folder.firstPage)
            try store.appendApplication(LaunchpadApplicationRecord(title: "Beta", bundleIdentifier: "com.example.beta", itemFlags: 0x400), to: pageIdentifier)

            #expect(try store.clearRecentlyAdded(forBundleIdentifiers: ["com.example.alpha"]))
            #expect(try store.layout().applications.map(\.isRecentlyAdded) == [false, false, true])
            #expect(try !store.clearRecentlyAdded(forBundleIdentifiers: ["com.example.alpha"]))
        }
    }

    @Test("an App Store application that appears is marked as recently added, any other is not")
    func reconciliationMarksAppStoreApplications() throws {
        try withTemporaryDirectory { directoryURL in
            let applicationsURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
            let storeBundleURL = try ApplicationBundleFixture(name: "Alpha", bundleIdentifier: "com.example.alpha", hasAppStoreReceipt: true).write(in: applicationsURL)
            let otherBundleURL = try ApplicationBundleFixture(name: "Beta", bundleIdentifier: "com.example.beta").write(in: applicationsURL)
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))

            try store.apply(
                LayoutReconciliation(applicationsToAdd: [
                    DiscoveredApplication(url: storeBundleURL, bundleIdentifier: "com.example.alpha", title: "Alpha"),
                    DiscoveredApplication(url: otherBundleURL, bundleIdentifier: "com.example.beta", title: "Beta"),
                ]),
                itemsPerPage: 35
            )

            #expect(try store.layout().applications.map(\.isRecentlyAdded) == [true, false])
        }
    }

    @Test("the layout built on first start marks nothing")
    func firstLayoutMarksNothing() throws {
        try withTemporaryDirectory { directoryURL in
            let applicationsURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
            let storeBundleURL = try ApplicationBundleFixture(name: "Alpha", bundleIdentifier: "com.example.alpha", hasAppStoreReceipt: true).write(in: applicationsURL)
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))

            try store.buildDefaultLayout(
                from: [DiscoveredApplication(url: storeBundleURL, bundleIdentifier: "com.example.alpha", title: "Alpha")],
                mainPage: [],
                itemsPerPage: 35
            )

            #expect(try store.layout().applications.map(\.isRecentlyAdded) == [false])
        }
    }

    @Test(
        "an application has been launched once it was used after it was added",
        arguments: [
            (nil, Date(timeIntervalSince1970: 100), false), // never used
            (Date(timeIntervalSince1970: 200), Date(timeIntervalSince1970: 100), true),
            (Date(timeIntervalSince1970: 50), Date(timeIntervalSince1970: 100), false), // used before this copy came
            (Date(timeIntervalSince1970: 200), nil, true),
        ] as [(Date?, Date?, Bool)]
    )
    func launchedSinceAdded(lastUsedDate: Date?, dateAdded: Date?, expectedLaunched: Bool) {
        #expect(RecentlyAddedApplications.hasBeenLaunched(lastUsedDate: lastUsedDate, dateAdded: dateAdded) == expectedLaunched)
    }
}
