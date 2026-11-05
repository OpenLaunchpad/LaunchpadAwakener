import Foundation
import LaunchpadAwakenerPayloadCore
import Testing
import TestingSupport

/// Rearranging the layout the way dragging does, checked by reading the layout back.
@Suite("Rearranging the layout")
struct LaunchpadStoreEditingTests {
    /// A store with `pageTitles` laid out as root pages of applications.
    private static func makeStore(in directoryURL: URL, pageTitles: [[String]]) throws -> LaunchpadStore {
        let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))
        for titles in pageTitles {
            let pageIdentifier = try store.appendPage(to: store.rootIdentifier)
            for title in titles {
                try store.appendApplication(LaunchpadApplicationRecord(title: title, bundleIdentifier: "com.example.\(title.lowercased())"), to: pageIdentifier)
            }
        }
        return store
    }

    private static func pageTitles(of store: LaunchpadStore) throws -> [[String]] {
        try store.layout().pages.map { page in page.items.map(\.title) }
    }

    private static func identifier(of title: String, in store: LaunchpadStore) throws -> LaunchpadItemIdentifier {
        try #require(try store.layout().pages.flatMap(\.items).first { $0.title == title }?.identifier)
    }

    @Test("an item moves to another place on its page")
    func moveWithinPage() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pageTitles: [["A", "B", "C", "D"]])
            let pageIdentifier = try #require(try store.layout().pages.first?.identifier)

            try store.moveItem(try Self.identifier(of: "D", in: store), toIndex: 1, onPage: pageIdentifier, itemsPerPage: 4)

            #expect(try Self.pageTitles(of: store) == [["A", "D", "B", "C"]])
        }
    }

    @Test("moving onto a full page pushes its last item to the next page")
    func moveOntoFullPageOverflows() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pageTitles: [["A", "B", "C"], ["D", "E"]])
            let firstPageIdentifier = try #require(try store.layout().pages.first?.identifier)

            try store.moveItem(try Self.identifier(of: "E", in: store), toIndex: 0, onPage: firstPageIdentifier, itemsPerPage: 3)

            #expect(try Self.pageTitles(of: store) == [["E", "A", "B"], ["C", "D"]])
        }
    }

    @Test("a page left empty by a move disappears")
    func emptiedPageIsRemoved() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pageTitles: [["A", "B"], ["C"]])
            let firstPageIdentifier = try #require(try store.layout().pages.first?.identifier)

            try store.moveItem(try Self.identifier(of: "C", in: store), toIndex: 2, onPage: firstPageIdentifier, itemsPerPage: 35)

            #expect(try Self.pageTitles(of: store) == [["A", "B", "C"]])
        }
    }

    @Test("dropping one application on another makes a folder of both, where the target was")
    func makeFolder() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pageTitles: [["A", "B", "C"]])

            let folderIdentifier = try store.makeFolder(
                merging: try Self.identifier(of: "C", in: store),
                with: try Self.identifier(of: "A", in: store),
                title: "Tools",
                itemsPerPage: 35
            )

            let layout = try store.layout()
            #expect(layout.pages.map { page in page.items.map(\.title) } == [["Tools", "B"]])
            let folder = try #require(layout.folders.first)
            #expect(folder.identifier == folderIdentifier)
            #expect(folder.applications.map(\.title) == ["A", "C"])
        }
    }

    @Test("an application dropped on a folder goes to its end")
    func moveIntoFolder() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pageTitles: [["A", "B", "C", "D"]])
            let folderIdentifier = try store.makeFolder(
                merging: try Self.identifier(of: "B", in: store),
                with: try Self.identifier(of: "A", in: store),
                title: "Tools",
                itemsPerPage: 35
            )

            try store.moveItem(try Self.identifier(of: "D", in: store), intoFolder: folderIdentifier, itemsPerPage: 35)

            let layout = try store.layout()
            #expect(layout.pages.map { page in page.items.map(\.title) } == [["Tools", "C"]])
            #expect(layout.folders.first?.applications.map(\.title) == ["A", "B", "D"])
        }
    }

    @Test("a folder whose last application is dragged out disappears")
    func emptiedFolderIsRemoved() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try Self.makeStore(in: directoryURL, pageTitles: [["A", "B"]])
            let pageIdentifier = try #require(try store.layout().pages.first?.identifier)
            let folderIdentifier = try store.makeFolder(
                merging: try Self.identifier(of: "B", in: store),
                with: try Self.identifier(of: "A", in: store),
                title: "Tools",
                itemsPerPage: 35
            )
            let folderApplications = try #require(try store.layout().folders.first?.applications)

            for application in folderApplications {
                try store.moveItem(application.identifier, toIndex: 1, onPage: pageIdentifier, itemsPerPage: 35)
            }

            let layout = try store.layout()
            #expect(layout.folders.isEmpty)
            #expect(!layout.pages.flatMap(\.items).contains { $0.identifier == folderIdentifier })
            #expect(Set(layout.applications.map(\.title)) == ["A", "B"])
        }
    }

    @Test("a renamed folder keeps its name after the database is reopened")
    func renameSurvivesReopening() throws {
        try withTemporaryDirectory { directoryURL in
            let databaseURL = directoryURL.appendingPathComponent("Launchpad.db")
            do {
                let store = try Self.makeStore(in: directoryURL, pageTitles: [["A", "B"]])
                let folderIdentifier = try store.makeFolder(
                    merging: try Self.identifier(of: "B", in: store),
                    with: try Self.identifier(of: "A", in: store),
                    title: "Tools",
                    itemsPerPage: 35
                )
                try store.renameFolder(folderIdentifier, to: "Utilities")
            }

            let reopenedStore = try LaunchpadStore(databaseURL: databaseURL)
            #expect(try reopenedStore.layout().folders.first?.title == "Utilities")
        }
    }
}
