import Foundation
import LaunchpadAwakenerSpringboardCore
import Testing
import TestingSupport

/// The edits the app's organizer makes: several items at once, folders made and dissolved, a page or a
/// folder put in a new order. Checked by reading the layout back.
@Suite("Arranging several items at once")
struct LaunchpadArrangingTests {
    enum Entry {
        case application(String)
        /// A folder and its pages of applications.
        case folder(String, [[String]])
    }

    private static func makeStore(in directoryURL: URL, pages: [[Entry]]) throws -> LaunchpadStore {
        let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))
        for entries in pages {
            let pageIdentifier = try store.appendPage(to: store.rootIdentifier)
            for entry in entries {
                switch entry {
                case .application(let title):
                    try store.appendApplication(Self.record(title), to: pageIdentifier)
                case .folder(let title, let folderPages):
                    let folder = try store.appendFolder(titled: title, to: pageIdentifier)
                    for (folderPageIndex, titles) in folderPages.enumerated() {
                        let folderPageIdentifier = folderPageIndex == 0 ? folder.firstPage : try store.appendPage(to: folder.folder)
                        for title in titles {
                            try store.appendApplication(Self.record(title), to: folderPageIdentifier)
                        }
                    }
                }
            }
        }
        return store
    }

    private static func record(_ title: String) -> LaunchpadApplicationRecord {
        LaunchpadApplicationRecord(title: title, bundleIdentifier: "com.example.\(title.lowercased())")
    }

    private static func pageTitles(of store: LaunchpadStore) throws -> [[String]] {
        try store.layout().pages.map { page in page.items.map(\.title) }
    }

    private static func folderPageTitles(_ folderTitle: String, in store: LaunchpadStore) throws -> [[String]] {
        let folder = try #require(try store.layout().folders.first { $0.title == folderTitle })
        return folder.pages.map { folderPage in folderPage.applications.map(\.title) }
    }

    private static func identifiers(of titles: [String], in store: LaunchpadStore) throws -> [LaunchpadItemIdentifier] {
        let layout = try store.layout()
        let items: [(title: String, identifier: LaunchpadItemIdentifier)] =
            layout.pages.flatMap(\.items).map { ($0.title, $0.identifier) } + layout.applications.map { ($0.title, $0.identifier) }
        return try titles.map { title in try #require(items.first { $0.title == title }?.identifier) }
    }

    private static func pageIdentifier(at pageIndex: Int, in store: LaunchpadStore) throws -> LaunchpadItemIdentifier {
        let pages = try store.layout().pages
        try #require(pages.indices.contains(pageIndex))
        return pages[pageIndex].identifier
    }

    @Test("several items go to the end of a page in order, out of their folders")
    func moveItemsToEndOfPage() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pages: [
                [.application("A"), .folder("F", [["B", "C", "D"]])],
                [.application("E")],
            ])

            try store.moveItems(try Self.identifiers(of: ["E", "C", "B"], in: store), toEndOfPage: try Self.pageIdentifier(at: 0, in: store), itemsPerPage: 35)

            // F is left with D alone, so it dissolves and D takes its place.
            #expect(try Self.pageTitles(of: store) == [["A", "D", "E", "C", "B"]])
        }
    }

    @Test("what does not fit on the page flows on to the next one, in order")
    func movedItemsOverflowInOrder() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pages: [
                [.application("A"), .application("B"), .application("C")],
                [.application("D"), .application("E"), .application("F")],
            ])

            try store.moveItems(try Self.identifiers(of: ["D", "E", "F"], in: store), toEndOfPage: try Self.pageIdentifier(at: 0, in: store), itemsPerPage: 4)

            #expect(try Self.pageTitles(of: store) == [["A", "B", "C", "D"], ["E", "F"]])
        }
    }

    @Test("several items go onto a new last page, in order")
    func moveItemsToNewLastPage() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pages: [[.application("A"), .application("B"), .application("C")]])

            try store.moveItemsToNewLastPage(try Self.identifiers(of: ["C", "A"], in: store), itemsPerPage: 35)

            #expect(try Self.pageTitles(of: store) == [["B"], ["C", "A"]])
        }
    }

    @Test("several applications go into a folder in order, and those already in it stay")
    func moveItemsIntoFolder() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pages: [[.application("A"), .folder("F", [["B", "C"]]), .application("D"), .application("E")]])
            let folderIdentifier = try #require(try Self.identifiers(of: ["F"], in: store).first)

            try store.moveItems(try Self.identifiers(of: ["E", "B", "D"], in: store), intoFolder: folderIdentifier, itemsPerPage: 35)

            #expect(try Self.pageTitles(of: store) == [["A", "F"]])
            #expect(try Self.folderPageTitles("F", in: store) == [["B", "C", "E", "D"]])
        }
    }

    @Test("a folder does not go into a folder, and nothing moves")
    func folderDoesNotGoIntoFolder() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pages: [[.application("A"), .folder("F", [["B", "C"]]), .folder("G", [["D", "E"]])]])
            let folderIdentifiers = try Self.identifiers(of: ["F", "G"], in: store)

            #expect(throws: LaunchpadStoreError.unexpectedItemType(folderIdentifiers[1], expected: "application")) {
                try store.moveItems(try Self.identifiers(of: ["A", "G"], in: store), intoFolder: folderIdentifiers[0], itemsPerPage: 35)
            }
            #expect(try Self.pageTitles(of: store) == [["A", "F", "G"]])
        }
    }

    @Test("a new folder of several applications goes where the first of them was")
    func makeFolderOfSeveralApplications() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pages: [[.application("A"), .application("B"), .application("C"), .application("D")]])

            try store.makeFolder(containing: try Self.identifiers(of: ["C", "A", "D"], in: store), title: "T", itemsPerPage: 35)

            #expect(try Self.pageTitles(of: store) == [["B", "T"]])
            #expect(try Self.folderPageTitles("T", in: store) == [["C", "A", "D"]])
        }
    }

    @Test("a new folder whose first application was in a folder goes just after that folder")
    func makeFolderAfterTheFolderOfItsFirstApplication() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pages: [[.application("A"), .folder("F", [["B", "C", "D"]]), .application("E")]])

            try store.makeFolder(containing: try Self.identifiers(of: ["C", "E"], in: store), title: "T", itemsPerPage: 35)

            #expect(try Self.pageTitles(of: store) == [["A", "F", "T"]])
            #expect(try Self.folderPageTitles("F", in: store) == [["B", "D"]])
            #expect(try Self.folderPageTitles("T", in: store) == [["C", "E"]])
        }
    }

    @Test("a folder of one application is not made")
    func folderNeedsTwoApplications() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pages: [[.application("A"), .application("B")]])

            #expect(throws: LaunchpadStoreError.tooFewApplicationsForFolder) {
                try store.makeFolder(containing: try Self.identifiers(of: ["A", "A"], in: store), title: "T", itemsPerPage: 35)
            }
            #expect(try Self.pageTitles(of: store) == [["A", "B"]])
        }
    }

    @Test("dissolving a folder puts its applications where it was, in order")
    func dissolveFolder() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pages: [[.application("A"), .folder("F", [["B", "C"], ["D"]]), .application("E")]])

            try store.dissolveFolder(try #require(try Self.identifiers(of: ["F"], in: store).first), itemsPerPage: 35)

            #expect(try Self.pageTitles(of: store) == [["A", "B", "C", "D", "E"]])
            #expect(try store.layout().folders.isEmpty)
        }
    }

    @Test("a page is put in a new order, which must hold exactly its items")
    func arrangePage() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pages: [[.application("A"), .folder("F", [["B", "C"]]), .application("D")]])
            let pageIdentifier = try Self.pageIdentifier(at: 0, in: store)

            try store.arrangeItems(of: pageIdentifier, inOrder: try Self.identifiers(of: ["D", "A", "F"], in: store), itemsPerPage: 35)
            #expect(try Self.pageTitles(of: store) == [["D", "A", "F"]])

            #expect(throws: LaunchpadStoreError.arrangementDoesNotMatch(pageIdentifier)) {
                try store.arrangeItems(of: pageIdentifier, inOrder: try Self.identifiers(of: ["D", "A"], in: store), itemsPerPage: 35)
            }
            #expect(try Self.pageTitles(of: store) == [["D", "A", "F"]])
        }
    }

    @Test("a folder's applications are put in a new order across its pages")
    func arrangeFolder() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pages: [[.folder("F", [["A", "B"], ["C"]])]])

            try store.arrangeItems(
                of: try #require(try Self.identifiers(of: ["F"], in: store).first),
                inOrder: try Self.identifiers(of: ["C", "B", "A"], in: store),
                itemsPerPage: 2
            )

            #expect(try Self.folderPageTitles("F", in: store) == [["C", "B"], ["A"]])
        }
    }
}

@Suite("Editing several items through the library")
struct LaunchpadLibraryBatchTests {
    private static func startedLibrary(in directoryURL: URL, titles: [String]) async throws -> LaunchpadLibrary {
        for title in titles {
            try ApplicationBundleFixture(name: title, bundleIdentifier: "com.example.\(title.lowercased())")
                .write(in: directoryURL.appendingPathComponent("Applications", isDirectory: true))
        }
        let legacyDatabaseURL = directoryURL.appendingPathComponent("legacy.db")
        try LegacyLaunchpadDatabaseFixture(pages: [titles.map { .application(title: $0, bundleIdentifier: "com.example.\($0.lowercased())") }])
            .write(to: legacyDatabaseURL)
        let library = LaunchpadLibrary(
            configuration: LaunchpadLibrary.Configuration(
                databaseURL: directoryURL.appendingPathComponent("Store/Launchpad.db"),
                legacyDatabaseURL: legacyDatabaseURL,
                searchDirectories: [directoryURL.appendingPathComponent("Applications", isDirectory: true)],
                exclusionList: .standard,
                itemsPerPage: 35,
                installedBundleURLs: { _ in [] }
            ),
            layoutHandler: { _ in }
        )
        await library.start(watchesApplicationDirectories: false)
        return library
    }

    @Test("a batch is stored together, and the revision goes up once")
    func batchIsStoredTogether() async throws {
        try await withTemporaryDirectory { directoryURL in
            let library = try await Self.startedLibrary(in: directoryURL, titles: ["Alpha", "Beta", "Gamma"])
            let revision = await library.revision
            let applications = await library.layout.applications

            let result = await library.apply(
                [
                    .makeFolderContaining([applications[0].identifier, applications[2].identifier], title: "Pair"),
                    .moveItemsToNewLastPage([applications[1].identifier]),
                ],
                expectedRevision: revision
            )

            #expect(result == .applied(revision: revision + 1))
            #expect(await library.layout.pages.map { page in page.items.map(\.title) } == [["Pair"], ["Beta"]])
        }
    }

    @Test("a batch worked out from an older layout is turned away, and nothing changes")
    func staleBatchIsTurnedAway() async throws {
        try await withTemporaryDirectory { directoryURL in
            let library = try await Self.startedLibrary(in: directoryURL, titles: ["Alpha", "Beta", "Gamma"])
            let revision = await library.revision
            let applications = await library.layout.applications
            _ = await library.apply([.moveItemsToNewLastPage([applications[2].identifier])], expectedRevision: revision)

            let result = await library.apply([.moveItemsToNewLastPage([applications[0].identifier])], expectedRevision: revision)

            #expect(result == .staleRevision(currentRevision: revision + 1))
            #expect(await library.layout.pages.map { page in page.items.map(\.title) } == [["Alpha", "Beta"], ["Gamma"]])
        }
    }

    @Test("when one edit of a batch fails, none of them is stored")
    func failedBatchChangesNothing() async throws {
        try await withTemporaryDirectory { directoryURL in
            let library = try await Self.startedLibrary(in: directoryURL, titles: ["Alpha", "Beta", "Gamma"])
            let revision = await library.revision
            let applications = await library.layout.applications

            let result = await library.apply(
                [
                    .makeFolderContaining([applications[0].identifier, applications[1].identifier], title: "Pair"),
                    .dissolveFolder(applications[2].identifier),
                ],
                expectedRevision: revision
            )

            guard case .failed = result else {
                Issue.record("Expected the batch to fail, got \(result)")
                return
            }
            #expect(await library.revision == revision)
            let reopenedStore = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Store/Launchpad.db"))
            #expect(try reopenedStore.layout().pages.map { page in page.items.map(\.title) } == [["Alpha", "Beta", "Gamma"]])
        }
    }
}
