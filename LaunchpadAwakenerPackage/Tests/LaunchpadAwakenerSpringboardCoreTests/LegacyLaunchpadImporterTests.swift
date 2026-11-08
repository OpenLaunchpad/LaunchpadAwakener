import Foundation
import LaunchpadAwakenerSpringboardCore
import Testing
import TestingSupport

@Suite("Importing macOS 15's layout")
struct LegacyLaunchpadImporterTests {
    private static let fixture = LegacyLaunchpadDatabaseFixture(
        pages: [
            [
                .application(title: "Alpha", bundleIdentifier: "com.example.alpha"),
                .folder(
                    title: "Utilities",
                    pages: [
                        [
                            .application(title: "Beta", bundleIdentifier: "com.example.beta"),
                            .application(title: "Gamma", bundleIdentifier: "com.example.gamma"),
                        ],
                        [.application(title: "Delta", bundleIdentifier: "com.example.delta")],
                    ]
                ),
                .application(title: "Epsilon", bundleIdentifier: "com.example.epsilon"),
            ],
            [
                .application(title: "Zeta", bundleIdentifier: "com.example.zeta"),
                .downloadingApplication(title: "Eta", bundleIdentifier: "com.example.eta"),
            ],
            [],
        ],
        holdingPageItems: [.application(title: "Held", bundleIdentifier: "com.example.held")]
    )

    @Test("visible pages, folders and the order of applications are kept")
    func visibleLayoutIsKept() throws {
        try withTemporaryDirectory { directoryURL in
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try Self.fixture.write(to: legacyDatabaseURL)
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))

            try LegacyLaunchpadImporter.importLayout(fromLegacyDatabaseAt: legacyDatabaseURL, into: store)

            let layout = try store.layout()
            #expect(layout.pages.map { page in page.items.map(\.title) } == [["Alpha", "Utilities", "Epsilon"], ["Zeta"]])
            let folder = try #require(layout.folders.first)
            #expect(folder.pages.map { folderPage in folderPage.applications.map(\.title) } == [["Beta", "Gamma"], ["Delta"]])
        }
    }

    @Test("the summary counts what was imported")
    func summaryCountsImportedItems() throws {
        try withTemporaryDirectory { directoryURL in
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try Self.fixture.write(to: legacyDatabaseURL)
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))

            let summary = try LegacyLaunchpadImporter.importLayout(fromLegacyDatabaseAt: legacyDatabaseURL, into: store)

            #expect(summary == LegacyLaunchpadImporter.Summary(pageCount: 2, folderCount: 1, applicationCount: 6))
        }
    }

    @Test("icons macOS 15 cached come along")
    func cachedIconsAreImported() throws {
        try withTemporaryDirectory { directoryURL in
            let iconPNGData = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(
                pages: [[.application(title: "Alpha", bundleIdentifier: "com.example.alpha", iconPNGData: iconPNGData)]]
            ).write(to: legacyDatabaseURL)
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))

            try LegacyLaunchpadImporter.importLayout(fromLegacyDatabaseAt: legacyDatabaseURL, into: store)

            #expect(try store.layout().applications.first?.legacyIconPNGData == iconPNGData)
        }
    }

    @Test("a store that already has pages is left alone")
    func storeWithPagesIsRefused() throws {
        try withTemporaryDirectory { directoryURL in
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try Self.fixture.write(to: legacyDatabaseURL)
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))
            try store.appendApplicationToLastPage(LaunchpadApplicationRecord(title: "Existing", bundleIdentifier: "com.example.existing"), itemsPerPage: 35)

            #expect(throws: LegacyLaunchpadImporter.ImportError.storeAlreadyHasPages) {
                try LegacyLaunchpadImporter.importLayout(fromLegacyDatabaseAt: legacyDatabaseURL, into: store)
            }
            #expect(try store.layout().applications.map(\.title) == ["Existing"])
        }
    }

    /// The standalone app starts from the injected springboard's library, which keeps macOS 15's tables.
    @Test("a library the springboard itself wrote imports with its pages, folders and blue dots")
    func injectedLibraryImports() throws {
        try withTemporaryDirectory { directoryURL in
            let injectedLibraryURL = directoryURL.appendingPathComponent("Injected.db")
            do {
                let injectedStore = try LaunchpadStore(databaseURL: injectedLibraryURL)
                let firstPage = try injectedStore.appendPage(to: injectedStore.rootIdentifier)
                try injectedStore.appendApplication(LaunchpadApplicationRecord(title: "Alpha", bundleIdentifier: "com.example.alpha"), to: firstPage)
                let folder = try injectedStore.appendFolder(titled: "Utilities", to: firstPage)
                try injectedStore.appendApplication(LaunchpadApplicationRecord(title: "Beta", bundleIdentifier: "com.example.beta"), to: folder.firstPage)
                try injectedStore.appendApplication(LaunchpadApplicationRecord(title: "Gamma", bundleIdentifier: "com.example.gamma"), to: folder.firstPage)
                let secondPage = try injectedStore.appendPage(to: injectedStore.rootIdentifier)
                try injectedStore.appendApplication(
                    LaunchpadApplicationRecord(title: "Delta", bundleIdentifier: "com.example.delta", itemFlags: LaunchpadDatabaseSchema.ItemFlags.recentlyAdded),
                    to: secondPage
                )
            }
            let standaloneStore = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Standalone.db"))

            try LegacyLaunchpadImporter.importLayout(fromLegacyDatabaseAt: injectedLibraryURL, into: standaloneStore)

            let layout = try standaloneStore.layout()
            #expect(layout.pages.map { page in page.items.map(\.title) } == [["Alpha", "Utilities"], ["Delta"]])
            #expect(layout.folders.first?.pages.first?.applications.map(\.title) == ["Beta", "Gamma"])
            #expect(layout.applications.filter(\.isRecentlyAdded).map(\.title) == ["Delta"])
        }
    }
}
