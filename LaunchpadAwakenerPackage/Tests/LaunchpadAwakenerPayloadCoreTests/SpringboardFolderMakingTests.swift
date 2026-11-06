import Foundation
import LaunchpadAwakenerPayloadCore
import Testing

/// The folder a drop shows before the stored layout comes back must match what the store will make.
@Suite("Showing a folder changed by a drop")
struct SpringboardFolderMakingTests {
    private static func application(_ title: String, rowIdentifier: Int64) -> LaunchpadApplication {
        LaunchpadApplication(
            identifier: LaunchpadItemIdentifier(rowIdentifier: rowIdentifier),
            title: title,
            bundleIdentifier: "com.example.\(title.lowercased())",
            bookmarkData: nil,
            legacyIconPNGData: nil,
            bundleURL: nil
        )
    }

    private static func folder(pages: [[String]]) -> LaunchpadFolder {
        var nextRowIdentifier: Int64 = 100
        return LaunchpadFolder(
            identifier: LaunchpadItemIdentifier(rowIdentifier: 1),
            title: "Tools",
            pages: pages.enumerated().map { pageIndex, titles in
                LaunchpadFolderPage(
                    identifier: LaunchpadItemIdentifier(rowIdentifier: Int64(10 + pageIndex)),
                    applications: titles.map { title in
                        nextRowIdentifier += 1
                        return application(title, rowIdentifier: nextRowIdentifier)
                    }
                )
            }
        )
    }

    @Test("a dropped application joins the end of the folder's last page")
    func appendingToLastPage() {
        let folder = Self.folder(pages: [["A", "B"], ["C"]])

        let updatedFolder = folder.appending(Self.application("D", rowIdentifier: 200), itemsPerPage: 2)

        #expect(updatedFolder.pages.map { page in page.applications.map(\.title) } == [["A", "B"], ["C", "D"]])
    }

    @Test("a dropped application starts a new page when the last one is full")
    func appendingPastFullPage() {
        let folder = Self.folder(pages: [["A", "B"]])

        let updatedFolder = folder.appending(Self.application("C", rowIdentifier: 200), itemsPerPage: 2)

        #expect(updatedFolder.pages.map { page in page.applications.map(\.title) } == [["A", "B"], ["C"]])
    }

    @Test("removing an application drops the page it leaves empty")
    func removingEmptiesPage() throws {
        let folder = Self.folder(pages: [["A", "B"], ["C"]])
        let applicationC = try #require(folder.applications.last)

        let updatedFolder = folder.removing(applicationC.identifier)

        #expect(updatedFolder.pages.map { page in page.applications.map(\.title) } == [["A", "B"]])
    }
}
