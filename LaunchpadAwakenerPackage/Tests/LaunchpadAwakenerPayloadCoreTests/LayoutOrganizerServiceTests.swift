import Foundation
import LaunchpadAwakenerPayloadInterface
import LaunchpadAwakenerSpringboardCore
import Testing
@testable import LaunchpadAwakenerPayloadCore

/// What the payload hands the organizer, and how the organizer's edits become the library's.
@Suite("Layout organizer service")
struct LayoutOrganizerServiceTests {
    private static func application(_ rowIdentifier: Int64, _ title: String, bundlePath: String?) -> LaunchpadApplication {
        LaunchpadApplication(
            identifier: LaunchpadItemIdentifier(rowIdentifier: rowIdentifier),
            title: title,
            bundleIdentifier: "com.example.\(title.lowercased())",
            bookmarkData: Data([1, 2, 3]),
            legacyIconPNGData: Data([4, 5, 6]),
            bundleURL: bundlePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
    }

    @Test("the snapshot keeps pages, folders and their pages, titles and bundle paths, and nothing else")
    func snapshotOfLayout() {
        let layout = LaunchpadLayout(pages: [
            LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 2), items: [
                .application(Self.application(3, "Alpha", bundlePath: "/Applications/Alpha.app")),
                .folder(LaunchpadFolder(
                    identifier: LaunchpadItemIdentifier(rowIdentifier: 4),
                    title: "Tools",
                    pages: [
                        LaunchpadFolderPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 5), applications: [Self.application(6, "Hammer", bundlePath: nil)]),
                        LaunchpadFolderPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 7), applications: [Self.application(8, "Saw", bundlePath: "/Applications/Saw.app")]),
                    ]
                )),
            ]),
        ])

        let snapshot = LayoutSnapshot(layout, revision: 12)

        #expect(snapshot == LayoutSnapshot(revision: 12, pages: [
            LayoutSnapshot.Page(identifier: 2, items: [
                .application(LayoutSnapshot.Application(identifier: 3, title: "Alpha", bundleIdentifier: "com.example.alpha", bundlePath: "/Applications/Alpha.app")),
                .folder(LayoutSnapshot.Folder(identifier: 4, title: "Tools", pages: [
                    [LayoutSnapshot.Application(identifier: 6, title: "Hammer", bundleIdentifier: "com.example.hammer", bundlePath: nil)],
                    [LayoutSnapshot.Application(identifier: 8, title: "Saw", bundleIdentifier: "com.example.saw", bundlePath: "/Applications/Saw.app")],
                ])),
            ]),
        ]))
    }

    @Test("each organizer edit becomes the library's edit of the same items")
    func editsMapToLibraryEdits() {
        func identifier(_ rowIdentifier: Int64) -> LaunchpadItemIdentifier {
            LaunchpadItemIdentifier(rowIdentifier: rowIdentifier)
        }
        #expect(LaunchpadEdit(.moveItemsToEndOfPage(items: [1, 2], page: 9)) == .moveItemsToEndOfPage([identifier(1), identifier(2)], page: identifier(9)))
        #expect(LaunchpadEdit(.moveItemsToNewLastPage(items: [3])) == .moveItemsToNewLastPage([identifier(3)]))
        #expect(LaunchpadEdit(.moveItemsIntoFolder(items: [4], folder: 8)) == .moveItemsIntoFolder([identifier(4)], folder: identifier(8)))
        #expect(LaunchpadEdit(.makeFolder(items: [5, 6], title: "Pair")) == .makeFolderContaining([identifier(5), identifier(6)], title: "Pair"))
        #expect(LaunchpadEdit(.renameFolder(folder: 8, title: "Kit")) == .renameFolder(identifier(8), title: "Kit"))
        #expect(LaunchpadEdit(.dissolveFolder(folder: 8)) == .dissolveFolder(identifier(8)))
        #expect(LaunchpadEdit(.arrange(container: 9, order: [2, 1])) == .arrange(identifier(9), order: [identifier(2), identifier(1)]))
    }
}
