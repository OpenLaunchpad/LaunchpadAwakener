import CoreGraphics
@testable import LaunchpadAwakenerSpringboardCore
import Testing

/// Where an opening folder's pictures and titles start, and a closing one's end, as macOS 15.5's
/// `-[ECSBGroupLayer _minimizeItemLayers]` (`0x10004D93C`) and `_minimizePagerElements` (`0x10004D6BC`)
/// placed them. Expected values are worked out by hand from those functions: a 104-point folder icon's
/// thumbnail grid is 68 points square (an 84-point frosted square inset by 8), here with its bottom left
/// corner at (10, 20).
@Suite("Folder opening and closing")
@MainActor
struct SpringboardFolderAnimationTests {
    private static let thumbnailGridFrame = CGRect(x: 10, y: 20, width: 68, height: 68)

    @Test("the first nine pictures shrink onto 18-point thumbnails 22 points apart, from the top left")
    func firstNinePicturesLieOnTheThumbnails() {
        let iconFrames = SpringboardFolderPanel.minimizedIconFrames(count: 9, thumbnailGridFrame: Self.thumbnailGridFrame, columnCount: 7)

        #expect(iconFrames.count == 9)
        #expect(iconFrames[0] == CGRect(x: 12, y: 68, width: 18, height: 18))
        #expect(iconFrames[2] == CGRect(x: 56, y: 68, width: 18, height: 18))
        #expect(iconFrames[4] == CGRect(x: 34, y: 46, width: 18, height: 18))
        #expect(iconFrames[8] == CGRect(x: 56, y: 24, width: 18, height: 18))
    }

    @Test("the pictures after the ninth carry on past the thumbnails the way 15's loop did")
    func laterPicturesCarryOnPastTheThumbnails() {
        let iconFrames = SpringboardFolderPanel.minimizedIconFrames(count: 16, thumbnailGridFrame: Self.thumbnailGridFrame, columnCount: 7)

        // The tenth under the grid's first column, then the fourth column of the second row onwards, a
        // row of seven counted from the third cell.
        #expect(iconFrames[9] == CGRect(x: 12, y: 2, width: 18, height: 18))
        #expect(iconFrames[10] == CGRect(x: 78, y: 46, width: 18, height: 18))
        #expect(iconFrames[14] == CGRect(x: 166, y: 46, width: 18, height: 18))
        #expect(iconFrames[15] == CGRect(x: 12, y: 24, width: 18, height: 18))
    }

    @Test("a minimized title is centred under its picture, truncated toward zero, its top on the picture's bottom")
    func minimizedTitleSitsUnderItsPicture() {
        let leftTitleFrame = SpringboardFolderPanel.minimizedLabelFrame(under: CGRect(x: 12, y: 68, width: 18, height: 18), labelSize: CGSize(width: 73, height: 16))
        let rightTitleFrame = SpringboardFolderPanel.minimizedLabelFrame(under: CGRect(x: 78, y: 46, width: 18, height: 18), labelSize: CGSize(width: 61, height: 16))

        #expect(leftTitleFrame == CGRect(x: -15, y: 52, width: 73, height: 16))
        #expect(rightTitleFrame == CGRect(x: 56, y: 30, width: 61, height: 16))
    }

    @Test("the folder's title starts and ends centred over the folder's cell, resting on its top")
    func folderTitleRestsOnTheCell() {
        let titleFrame = SpringboardFolderPanel.titleFrameOverFolder(cellRect: CGRect(x: 100, y: 600, width: 193, height: 169), titleSize: CGSize(width: 120, height: 34))

        #expect(titleFrame == CGRect(x: 136.5, y: 769, width: 120, height: 34))
    }
}
