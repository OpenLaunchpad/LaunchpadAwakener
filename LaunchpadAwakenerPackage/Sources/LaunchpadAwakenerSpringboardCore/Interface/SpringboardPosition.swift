import Foundation

/// Where the springboard stands: the main page it shows, and the folder open over it with that folder's
/// page.
///
/// macOS 15 built its Launchpad once for the Dock's lifetime, and hiding left both alone — it only cleared
/// the search, the selection and jiggle mode (`-[Springboard _cleanupBeforeExitAnimation]`, 15.5
/// `0x100030768`; `_cleanupAfterExitAnimation:openCount:`, `0x100030EF8`; `-[ECSBSpringboard setVisible:]`,
/// `0x10002E610`) — so it reopened where it had been left. This payload builds the springboard afresh for
/// every showing and carries a position from one to the next instead. Like 15's, it lives in memory only:
/// the Dock starting again starts on the first page.
package struct SpringboardPosition: Equatable, Sendable, CustomStringConvertible {
    package struct OpenFolder: Equatable, Sendable {
        package var identifier: LaunchpadItemIdentifier
        package var pageIndex: Int

        package init(identifier: LaunchpadItemIdentifier, pageIndex: Int) {
            self.identifier = identifier
            self.pageIndex = pageIndex
        }
    }

    /// What a position comes to in a layout that may have changed since it was taken.
    package struct Resolution: Equatable, Sendable {
        package var mainPageIndex: Int
        /// The folder to open over the main page, as the layout has it now; nil for none.
        package var folder: LaunchpadFolder?
        package var folderPageIndex: Int
    }

    package var mainPageIndex: Int
    package var openFolder: OpenFolder?

    package init(mainPageIndex: Int = 0, openFolder: OpenFolder? = nil) {
        self.mainPageIndex = mainPageIndex
        self.openFolder = openFolder
    }

    /// The first page with nothing open: where the springboard starts once the Dock has started.
    package static let firstPage = SpringboardPosition()

    /// The page and the folder to show in `layout`. A folder still there opens on its page — clamped to the
    /// pages it has now — over the page it sits on; a folder gone since leaves the main page alone; a page
    /// gone since gives way to the last one.
    package func resolved(in layout: LaunchpadLayout) -> Resolution {
        if let openFolder {
            for (pageIndex, page) in layout.pages.enumerated() {
                for case .folder(let folder) in page.items where folder.identifier == openFolder.identifier {
                    let lastFolderPageIndex = max(folder.pages.count - 1, 0)
                    return Resolution(
                        mainPageIndex: pageIndex,
                        folder: folder,
                        folderPageIndex: min(max(openFolder.pageIndex, 0), lastFolderPageIndex)
                    )
                }
            }
        }
        let lastPageIndex = max(layout.pages.count - 1, 0)
        return Resolution(mainPageIndex: min(max(mainPageIndex, 0), lastPageIndex), folder: nil, folderPageIndex: 0)
    }

    package var description: String {
        guard let openFolder else { return "page \(mainPageIndex + 1)" }
        return "page \(mainPageIndex + 1), folder \(openFolder.identifier) open on its page \(openFolder.pageIndex + 1)"
    }
}
