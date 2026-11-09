import Foundation
import LaunchpadAwakenerSpringboardCore
import Testing
import TestingSupport

@Suite("Keeping the layout in line with what is installed")
struct LaunchpadLibraryTests {
    /// Checks bookmarks the way the Dock does, but asks LaunchServices for nothing: what it knows depends
    /// on the machine running the tests.
    private static func configuration(in directoryURL: URL, legacyDatabaseURL: URL?, itemsPerPage: Int = 35) -> LaunchpadLibrary.Configuration {
        LaunchpadLibrary.Configuration(
            databaseURL: directoryURL.appendingPathComponent("Store/Launchpad.db"),
            legacyDatabaseURL: legacyDatabaseURL,
            searchDirectories: [directoryURL.appendingPathComponent("Applications", isDirectory: true)],
            exclusionList: .standard,
            itemsPerPage: itemsPerPage,
            installedBundleURLs: { _ in [] }
        )
    }

    /// LaunchServices knowing a copy of every application, somewhere outside the search directories.
    private static func installedEverywhere(bundleIdentifier: String) -> [URL] {
        [URL(fileURLWithPath: "/Installed/\(bundleIdentifier).app", isDirectory: true)]
    }

    private static func installApplications(_ fixtures: [ApplicationBundleFixture], in directoryURL: URL) throws {
        for fixture in fixtures {
            try fixture.write(in: directoryURL.appendingPathComponent("Applications", isDirectory: true))
        }
    }

    private static func startedLibrary(configuration: LaunchpadLibrary.Configuration) async -> LaunchpadLayout {
        let library = LaunchpadLibrary(configuration: configuration, layoutHandler: { _ in })
        await library.start(watchesApplicationDirectories: false)
        return await library.layout
    }

    @Test("the first start imports macOS 15's layout and adds applications installed since")
    func firstStartImportsAndAddsNewApplications() async throws {
        try await withTemporaryDirectory { directoryURL in
            try Self.installApplications(
                [
                    ApplicationBundleFixture(name: "Alpha", bundleIdentifier: "com.example.alpha"),
                    ApplicationBundleFixture(name: "Beta", bundleIdentifier: "com.example.beta"),
                    ApplicationBundleFixture(name: "Gamma", bundleIdentifier: "com.example.gamma"),
                ],
                in: directoryURL
            )
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(
                pages: [[
                    .application(title: "Beta", bundleIdentifier: "com.example.beta"),
                    .application(title: "Alpha", bundleIdentifier: "com.example.alpha"),
                ]]
            ).write(to: legacyDatabaseURL)

            let layout = await Self.startedLibrary(configuration: Self.configuration(in: directoryURL, legacyDatabaseURL: legacyDatabaseURL))

            #expect(layout.pages.map { page in page.items.map(\.title) } == [["Beta", "Alpha", "Gamma"]])
        }
    }

    @Test("applications no longer installed are dropped, and so is a page they leave empty")
    func uninstalledApplicationsAreDropped() async throws {
        try await withTemporaryDirectory { directoryURL in
            try Self.installApplications([ApplicationBundleFixture(name: "Alpha", bundleIdentifier: "com.example.alpha")], in: directoryURL)
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(
                pages: [
                    [
                        .application(title: "Alpha", bundleIdentifier: "com.example.alpha"),
                        .folder(title: "Gone", pages: [[.application(title: "Omega", bundleIdentifier: "com.example.omega")]]),
                    ],
                    [.application(title: "Zeta", bundleIdentifier: "com.example.zeta")],
                ]
            ).write(to: legacyDatabaseURL)

            let layout = await Self.startedLibrary(configuration: Self.configuration(in: directoryURL, legacyDatabaseURL: legacyDatabaseURL))

            #expect(layout.pages.map { page in page.items.map(\.title) } == [["Alpha"]])
        }
    }

    @Test("an application installed somewhere discovery does not look keeps its place")
    func applicationsInstalledElsewhereStay() async throws {
        try await withTemporaryDirectory { directoryURL in
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(pages: [[.application(title: "Elsewhere", bundleIdentifier: "com.example.elsewhere")]])
                .write(to: legacyDatabaseURL)
            var configuration = Self.configuration(in: directoryURL, legacyDatabaseURL: legacyDatabaseURL)
            configuration.installedBundleURLs = { bundleIdentifier in
                bundleIdentifier == "com.example.elsewhere" ? [URL(fileURLWithPath: "/Elsewhere/Elsewhere.app", isDirectory: true)] : []
            }

            let layout = await Self.startedLibrary(configuration: configuration)

            #expect(layout.applications.map(\.title) == ["Elsewhere"])
        }
    }

    /// Mos, ChatGPT, Xcodes and PixelSnap were each replaced in place by a build with another bundle
    /// identifier. The old entry's bookmark still led to a bundle, so it counted as installed and stayed,
    /// while the new identifier was added beside it: the same application twice.
    @Test("an application replaced in place by one with another identifier is listed once, under the new one")
    func applicationReplacedInPlaceIsListedOnce() async throws {
        try await withTemporaryDirectory { directoryURL in
            let applicationsURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
            let bundleURL = try ApplicationBundleFixture(name: "Mos", bundleIdentifier: "com.example.mos.fork").write(in: applicationsURL)
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(pages: [[
                .application(title: "Mos", bundleIdentifier: "com.example.mos", bookmarkData: try bundleURL.bookmarkData()),
                .application(title: "Mos", bundleIdentifier: "com.example.mos.fork", bookmarkData: try bundleURL.bookmarkData()),
            ]]).write(to: legacyDatabaseURL)

            let layout = await Self.startedLibrary(configuration: Self.configuration(in: directoryURL, legacyDatabaseURL: legacyDatabaseURL))

            #expect(layout.applications.map(\.bundleIdentifier) == ["com.example.mos.fork"])
        }
    }

    /// Xcode-16.4.0 stayed after it was deleted, because other Xcodes with the same identifier were
    /// still installed — each of them already in the layout under its own entry.
    @Test("a deleted application leaves even when other copies with its identifier are installed, each already listed")
    func deletedCopyLeavesWhenTheOtherCopiesAreListed() async throws {
        try await withTemporaryDirectory { directoryURL in
            let applicationsURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
            let releaseURL = try ApplicationBundleFixture(name: "Tool", bundleIdentifier: "com.example.tool").write(in: applicationsURL)
            let betaURL = try ApplicationBundleFixture(name: "Tool-Beta", bundleIdentifier: "com.example.tool").write(in: applicationsURL)
            let deletedURL = try ApplicationBundleFixture(name: "Tool-Old", bundleIdentifier: "com.example.tool").write(in: applicationsURL)
            let deletedBookmarkData = try deletedURL.bookmarkData()
            try FileManager.default.removeItem(at: deletedURL)
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(pages: [[
                .application(title: "Tool", bundleIdentifier: "com.example.tool", bookmarkData: try releaseURL.bookmarkData()),
                .application(title: "Tool-Beta", bundleIdentifier: "com.example.tool", bookmarkData: try betaURL.bookmarkData()),
                .application(title: "Tool-Old", bundleIdentifier: "com.example.tool", bookmarkData: deletedBookmarkData),
            ]]).write(to: legacyDatabaseURL)

            let layout = await Self.startedLibrary(configuration: Self.configuration(in: directoryURL, legacyDatabaseURL: legacyDatabaseURL))

            #expect(layout.applications.map(\.title) == ["Tool", "Tool-Beta"])
        }
    }

    /// IDA 9.2 to 9.5 and two of the three Xcodes were installed but never shown: their identifier was
    /// already in the layout.
    @Test("each installed copy of an application gets its own entry")
    func unlistedCopiesAreAdded() async throws {
        try await withTemporaryDirectory { directoryURL in
            let applicationsURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
            let releaseURL = try ApplicationBundleFixture(name: "Tool", bundleIdentifier: "com.example.tool").write(in: applicationsURL)
            try ApplicationBundleFixture(name: "Tool-Beta", bundleIdentifier: "com.example.tool").write(in: applicationsURL)
            try ApplicationBundleFixture(name: "Tool-Nightly", bundleIdentifier: "com.example.tool").write(in: applicationsURL)
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(pages: [[
                .application(title: "Tool", bundleIdentifier: "com.example.tool", bookmarkData: try releaseURL.bookmarkData()),
            ]]).write(to: legacyDatabaseURL)

            let layout = await Self.startedLibrary(configuration: Self.configuration(in: directoryURL, legacyDatabaseURL: legacyDatabaseURL))

            #expect(layout.applications.map(\.title) == ["Tool", "Tool-Beta", "Tool-Nightly"])
            #expect(layout.applications.map { $0.bundleURL?.standardizedFileURL.lastPathComponent } == ["Tool.app", "Tool-Beta.app", "Tool-Nightly.app"])
        }
    }

    /// Updaters and the App Store put a new bundle where the old one was; the bookmark still finds it there.
    @Test("an application updated by a new bundle at the same path keeps its place")
    func updatedApplicationKeepsItsPlace() async throws {
        try await withTemporaryDirectory { directoryURL in
            let applicationsURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
            let bundleURL = try ApplicationBundleFixture(name: "Tool", bundleIdentifier: "com.example.tool").write(in: applicationsURL)
            let bookmarkData = try bundleURL.bookmarkData()
            try FileManager.default.removeItem(at: bundleURL)
            try ApplicationBundleFixture(name: "Tool", bundleIdentifier: "com.example.tool").write(in: applicationsURL)
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(pages: [[
                .folder(title: "Tools", pages: [[
                    .application(title: "Tool", bundleIdentifier: "com.example.tool", bookmarkData: bookmarkData),
                    .application(title: "Other", bundleIdentifier: "com.example.other"),
                ]]),
            ]]).write(to: legacyDatabaseURL)
            var configuration = Self.configuration(in: directoryURL, legacyDatabaseURL: legacyDatabaseURL)
            configuration.installedBundleURLs = Self.installedEverywhere(bundleIdentifier:)

            let layout = await Self.startedLibrary(configuration: configuration)

            #expect(layout.folders.first?.applications.map(\.title) == ["Tool", "Other"])
            #expect(layout.applications.count == 2)
        }
    }

    @Test("copies of one application each open their own bundle")
    func copiesOpenTheirOwnBundles() async throws {
        try await withTemporaryDirectory { directoryURL in
            let applicationsURL = directoryURL.appendingPathComponent("Applications", isDirectory: true)
            let releaseURL = try ApplicationBundleFixture(name: "Tool", bundleIdentifier: "com.example.tool").write(in: applicationsURL)
            let betaURL = try ApplicationBundleFixture(name: "Tool-Beta", bundleIdentifier: "com.example.tool").write(in: applicationsURL)
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(pages: [[
                .application(title: "Tool-Beta", bundleIdentifier: "com.example.tool", bookmarkData: try betaURL.bookmarkData()),
                .application(title: "Tool", bundleIdentifier: "com.example.tool", bookmarkData: try releaseURL.bookmarkData()),
            ]]).write(to: legacyDatabaseURL)

            let layout = await Self.startedLibrary(configuration: Self.configuration(in: directoryURL, legacyDatabaseURL: legacyDatabaseURL))

            #expect(layout.applications.map { $0.bundleURL?.standardizedFileURL.lastPathComponent } == ["Tool-Beta.app", "Tool.app"])
        }
    }

    /// The test MacBook's layout holds App Cleaner & Uninstaller, which macOS 15's exclusion rules keep
    /// discovery from adding (its name has "Uninstall" in it). It is in the layout all the same, and an
    /// early version of the launcher rule took it out; it must stay.
    @Test("an application already in the layout stays, even where macOS 15's exclusion rules would have kept it out")
    func placedApplicationsMatchingMacOS15ExclusionsStay() async throws {
        try await withTemporaryDirectory { directoryURL in
            try Self.installApplications([
                ApplicationBundleFixture(name: "Alpha", bundleIdentifier: "com.example.alpha"),
                ApplicationBundleFixture(name: "App Cleaner & Uninstaller", bundleIdentifier: "com.nektony.App-Cleaner-SIII"),
            ], in: directoryURL)
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(pages: [[
                .application(title: "Alpha", bundleIdentifier: "com.example.alpha"),
                .application(title: "App Cleaner & Uninstaller", bundleIdentifier: "com.nektony.App-Cleaner-SIII"),
            ]]).write(to: legacyDatabaseURL)
            var configuration = Self.configuration(in: directoryURL, legacyDatabaseURL: legacyDatabaseURL)
            configuration.installedBundleURLs = Self.installedEverywhere(bundleIdentifier:)
            try #require(configuration.exclusionList.excludes(bundleIdentifier: "com.nektony.App-Cleaner-SIII", name: "App Cleaner & Uninstaller"))

            let layout = await Self.startedLibrary(configuration: configuration)

            #expect(layout.applications.map(\.title) == ["Alpha", "App Cleaner & Uninstaller"])
        }
    }

    /// Installing the standalone Launchpad put it into the injected one's layout before it was excluded.
    @Test("a launcher of Apps or of the standalone Launchpad leaves the layout, even though it is still installed")
    func launchersLeave() async throws {
        try await withTemporaryDirectory { directoryURL in
            try Self.installApplications([
                ApplicationBundleFixture(name: "Alpha", bundleIdentifier: "com.example.alpha"),
                ApplicationBundleFixture(name: "Launchpad", bundleIdentifier: "com.MxIris.LaunchpadAwakener.Launchpad.debug"),
            ], in: directoryURL)
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(pages: [[
                .application(title: "Alpha", bundleIdentifier: "com.example.alpha"),
                .application(title: "Launchpad", bundleIdentifier: "com.MxIris.LaunchpadAwakener.Launchpad.debug"),
            ]]).write(to: legacyDatabaseURL)
            var configuration = Self.configuration(in: directoryURL, legacyDatabaseURL: legacyDatabaseURL)
            configuration.installedBundleURLs = Self.installedEverywhere(bundleIdentifier:)

            let layout = await Self.startedLibrary(configuration: configuration)

            #expect(layout.applications.map(\.title) == ["Alpha"])
        }
    }

    @Test("the standalone Launchpad is kept out of every layout, in its debug and release builds", arguments: ["com.MxIris.LaunchpadAwakener.Launchpad", "com.MxIris.LaunchpadAwakener.Launchpad.debug"])
    func standaloneLaunchpadIsExcluded(bundleIdentifier: String) {
        #expect(ApplicationExclusionList.standard.excludes(bundleIdentifier: bundleIdentifier, name: "Launchpad"))
        #expect(!ApplicationExclusionList.standard.excludes(bundleIdentifier: "com.MxIris.LaunchpadAwakener", name: "LaunchpadAwakener"))
    }

    @Test("without a macOS 15 layout, the default first page comes first and the rest follows by name")
    func defaultLayoutWithoutLegacyDatabase() async throws {
        try await withTemporaryDirectory { directoryURL in
            try Self.installApplications(
                [
                    ApplicationBundleFixture(name: "Zed", bundleIdentifier: "com.example.zed"),
                    ApplicationBundleFixture(name: "Terminal", bundleIdentifier: "com.example.terminal"),
                    ApplicationBundleFixture(name: "Mail", bundleIdentifier: "com.example.mail"),
                    ApplicationBundleFixture(name: "Browser", bundleIdentifier: "com.example.browser"),
                    ApplicationBundleFixture(name: "Archive", bundleIdentifier: "com.example.archive"),
                ],
                in: directoryURL
            )
            var configuration = Self.configuration(in: directoryURL, legacyDatabaseURL: nil, itemsPerPage: 4)
            configuration.defaultMainPage = [
                .application(bundleIdentifier: "com.example.not-installed"),
                .application(bundleIdentifier: "com.example.browser"),
                .application(bundleIdentifier: "com.example.mail"),
                .folder(title: "Other", applicationBundleIdentifiers: ["com.example.terminal", "com.example.not-installed-either"]),
            ]

            let layout = await Self.startedLibrary(configuration: configuration)

            #expect(layout.pages.map { page in page.items.map(\.title) } == [["Browser", "Mail", "Other", "Archive"], ["Zed"]])
            #expect(layout.folders.first?.applications.map(\.title) == ["Terminal"])
        }
    }

    @Test("a later start keeps the stored layout instead of importing again")
    func laterStartsDoNotImportAgain() async throws {
        try await withTemporaryDirectory { directoryURL in
            try Self.installApplications(
                [
                    ApplicationBundleFixture(name: "Alpha", bundleIdentifier: "com.example.alpha"),
                    ApplicationBundleFixture(name: "Beta", bundleIdentifier: "com.example.beta"),
                ],
                in: directoryURL
            )
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(pages: [[.application(title: "Alpha", bundleIdentifier: "com.example.alpha")]])
                .write(to: legacyDatabaseURL)
            let configuration = Self.configuration(in: directoryURL, legacyDatabaseURL: legacyDatabaseURL)
            _ = await Self.startedLibrary(configuration: configuration)
            try FileManager.default.removeItem(at: legacyDatabaseURL)
            try LegacyLaunchpadDatabaseFixture(pages: [[.application(title: "Beta", bundleIdentifier: "com.example.beta")]])
                .write(to: legacyDatabaseURL)

            let layout = await Self.startedLibrary(configuration: configuration)

            #expect(layout.pages.map { page in page.items.map(\.title) } == [["Alpha", "Beta"]])
        }
    }
}

@Suite("Editing through the library")
struct LaunchpadLibraryEditingTests {
    @Test("an edit is stored and the new layout is published")
    func editIsStoredAndPublished() async throws {
        try await withTemporaryDirectory { directoryURL in
            for (name, bundleIdentifier) in [("Alpha", "com.example.alpha"), ("Beta", "com.example.beta")] {
                try ApplicationBundleFixture(name: name, bundleIdentifier: bundleIdentifier)
                    .write(in: directoryURL.appendingPathComponent("Applications", isDirectory: true))
            }
            let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
            try LegacyLaunchpadDatabaseFixture(pages: [[
                .application(title: "Alpha", bundleIdentifier: "com.example.alpha"),
                .application(title: "Beta", bundleIdentifier: "com.example.beta"),
            ]]).write(to: legacyDatabaseURL)
            let configuration = LaunchpadLibrary.Configuration(
                databaseURL: directoryURL.appendingPathComponent("Store/Launchpad.db"),
                legacyDatabaseURL: legacyDatabaseURL,
                searchDirectories: [directoryURL.appendingPathComponent("Applications", isDirectory: true)],
                exclusionList: .standard,
                itemsPerPage: 35,
                installedBundleURLs: { _ in [] }
            )
            let library = LaunchpadLibrary(configuration: configuration, layoutHandler: { _ in })
            await library.start(watchesApplicationDirectories: false)
            let applications = await library.layout.applications

            let isStored = await library.apply(.makeFolder(merging: applications[1].identifier, with: applications[0].identifier, title: "Pair"))

            #expect(isStored)
            #expect(await library.layout.folders.map(\.title) == ["Pair"])
            let reopenedStore = try LaunchpadStore(databaseURL: configuration.databaseURL)
            #expect(try reopenedStore.layout().folders.first?.applications.map(\.title) == ["Alpha", "Beta"])
        }
    }
}
