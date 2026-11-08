import Foundation
import LaunchpadAwakenerSpringboardCore
import Testing
import TestingSupport

@Suite("Launchpad store")
struct LaunchpadStoreTests {
    @Test("a new store has a root and no pages")
    func newStoreHasNoPages() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))
            #expect(try store.hasNoPages)
            #expect(try store.layout() == .empty)
        }
    }

    @Test("new applications fill the last page before a new page starts")
    func newApplicationsFillTheLastPage() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))
            for title in ["Alpha", "Beta", "Gamma"] {
                try store.appendApplicationToLastPage(
                    LaunchpadApplicationRecord(title: title, bundleIdentifier: "com.example.\(title.lowercased())"),
                    itemsPerPage: 2
                )
            }
            let pageTitles = try store.layout().pages.map { page in page.items.map(\.title) }
            #expect(pageTitles == [["Alpha", "Beta"], ["Gamma"]])
        }
    }

    @Test("the layout is the same after the database is reopened")
    func layoutSurvivesReopening() throws {
        try withTemporaryDirectory { directoryURL in
            let databaseURL = directoryURL.appendingPathComponent("Launchpad.db")
            let layoutBeforeReopening: LaunchpadLayout
            do {
                let store = try LaunchpadStore(databaseURL: databaseURL)
                let pageIdentifier = try store.appendPage(to: store.rootIdentifier)
                try store.appendApplication(LaunchpadApplicationRecord(title: "Alpha", bundleIdentifier: "com.example.alpha"), to: pageIdentifier)
                let folder = try store.appendFolder(titled: "Tools", to: pageIdentifier)
                try store.appendApplication(LaunchpadApplicationRecord(title: "Beta", bundleIdentifier: "com.example.beta"), to: folder.firstPage)
                layoutBeforeReopening = try store.layout()
            }
            let reopenedStore = try LaunchpadStore(databaseURL: databaseURL)
            #expect(try reopenedStore.layout() == layoutBeforeReopening)
            #expect(layoutBeforeReopening.pages.first?.items.map(\.title) == ["Alpha", "Tools"])
        }
    }

    @Test("removing a folder removes the applications inside it")
    func removingAFolderRemovesItsApplications() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))
            let pageIdentifier = try store.appendPage(to: store.rootIdentifier)
            let folder = try store.appendFolder(titled: "Tools", to: pageIdentifier)
            try store.appendApplication(LaunchpadApplicationRecord(title: "Beta", bundleIdentifier: "com.example.beta"), to: folder.firstPage)
            try store.appendApplication(LaunchpadApplicationRecord(title: "Gamma", bundleIdentifier: "com.example.gamma"), to: pageIdentifier)

            try store.removeItem(folder.folder)

            let layout = try store.layout()
            #expect(layout.applications.map(\.title) == ["Gamma"])
            #expect(layout.folders.isEmpty)
        }
    }
}
