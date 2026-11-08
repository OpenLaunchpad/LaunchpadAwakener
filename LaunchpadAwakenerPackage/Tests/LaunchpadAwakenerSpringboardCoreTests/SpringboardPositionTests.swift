import Foundation
import LaunchpadAwakenerSpringboardCore
import Testing

/// The springboard reopens where it was left, as macOS 15's Launchpad did, within the layout as it is now.
@Suite("Reopening where the springboard was left")
struct SpringboardPositionTests {
    private static func application(_ rowIdentifier: Int64) -> LaunchpadApplication {
        LaunchpadApplication(
            identifier: LaunchpadItemIdentifier(rowIdentifier: rowIdentifier),
            title: "Application \(rowIdentifier)",
            bundleIdentifier: "com.example.application\(rowIdentifier)",
            bookmarkData: nil,
            legacyIconPNGData: nil
        )
    }

    /// A folder of `pageCount` pages with one application on each.
    private static func folder(_ rowIdentifier: Int64, pageCount: Int) -> LaunchpadFolder {
        LaunchpadFolder(
            identifier: LaunchpadItemIdentifier(rowIdentifier: rowIdentifier),
            title: "Folder \(rowIdentifier)",
            pages: (0..<pageCount).map { pageIndex in
                let rowIdentifierOnPage = rowIdentifier * 100 + Int64(pageIndex)
                return LaunchpadFolderPage(
                    identifier: LaunchpadItemIdentifier(rowIdentifier: rowIdentifierOnPage),
                    applications: [application(rowIdentifierOnPage + 50)]
                )
            }
        )
    }

    private static let folderIdentifier = LaunchpadItemIdentifier(rowIdentifier: 50)

    /// Three pages; folder #50, three pages long, sits on the second.
    private static let layout = LaunchpadLayout(pages: [
        LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 1), items: [.application(application(10)), .application(application(11))]),
        LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 2), items: [.application(application(12)), .folder(folder(50, pageCount: 3))]),
        LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 3), items: [.application(application(13))]),
    ])

    @Test("the first showing opens on the first page with nothing open")
    func firstShowing() {
        let resolution = SpringboardPosition.firstPage.resolved(in: Self.layout)

        #expect(resolution.mainPageIndex == 0)
        #expect(resolution.folder == nil)
    }

    @Test("reopens on the page it was left on")
    func pageLeftOn() {
        let resolution = SpringboardPosition(mainPageIndex: 2).resolved(in: Self.layout)

        #expect(resolution.mainPageIndex == 2)
        #expect(resolution.folder == nil)
    }

    @Test("a page gone since gives way to the last page")
    func pageGoneSince() {
        let resolution = SpringboardPosition(mainPageIndex: 5).resolved(in: Self.layout)

        #expect(resolution.mainPageIndex == 2)
    }

    @Test("reopens with the folder that was open, on the folder's page it was left on")
    func folderLeftOpen() {
        let position = SpringboardPosition(mainPageIndex: 1, openFolder: SpringboardPosition.OpenFolder(identifier: Self.folderIdentifier, pageIndex: 2))

        let resolution = position.resolved(in: Self.layout)

        #expect(resolution.mainPageIndex == 1)
        #expect(resolution.folder?.identifier == Self.folderIdentifier)
        #expect(resolution.folderPageIndex == 2)
    }

    @Test("an open folder that moved since opens over the page it sits on now")
    func folderMovedSince() {
        let position = SpringboardPosition(mainPageIndex: 0, openFolder: SpringboardPosition.OpenFolder(identifier: Self.folderIdentifier, pageIndex: 0))

        let resolution = position.resolved(in: Self.layout)

        #expect(resolution.mainPageIndex == 1)
        #expect(resolution.folder?.identifier == Self.folderIdentifier)
    }

    @Test("an open folder that lost pages since opens on its last page")
    func folderLostPagesSince() {
        let position = SpringboardPosition(mainPageIndex: 1, openFolder: SpringboardPosition.OpenFolder(identifier: Self.folderIdentifier, pageIndex: 7))

        let resolution = position.resolved(in: Self.layout)

        #expect(resolution.folderPageIndex == 2)
    }

    @Test("an open folder gone since leaves only the page it was on")
    func folderGoneSince() {
        let missingFolder = SpringboardPosition.OpenFolder(identifier: LaunchpadItemIdentifier(rowIdentifier: 99), pageIndex: 1)

        let resolution = SpringboardPosition(mainPageIndex: 2, openFolder: missingFolder).resolved(in: Self.layout)

        #expect(resolution.mainPageIndex == 2)
        #expect(resolution.folder == nil)
    }

    @Test("an empty layout opens on the first page")
    func emptyLayout() {
        let resolution = SpringboardPosition(mainPageIndex: 3).resolved(in: .empty)

        #expect(resolution.mainPageIndex == 0)
        #expect(resolution.folder == nil)
    }
}
