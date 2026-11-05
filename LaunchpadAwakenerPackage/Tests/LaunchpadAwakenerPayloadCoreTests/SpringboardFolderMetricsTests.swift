import CoreGraphics
import LaunchpadAwakenerPayloadCore
import Testing

/// Expected values are the worked example of the macOS 15.5 folder specification
/// (`/Volumes/RE/Dock/15.5/Notes/LaunchpadFoldersAndDragging.md`, section 2.4): the main example's
/// screen with a folder of nine applications.
@Suite("Open folder geometry")
struct SpringboardFolderMetricsTests {
    private static let mainMetrics = SpringboardMetrics(
        SpringboardMetrics.Input(
            screenSize: CGSize(width: 1470, height: 956),
            dockOrientation: .bottom,
            dockThickness: 59,
            notchHeight: 0,
            rowCount: 5,
            columnCount: 7,
            zoomStyle: 0,
            labelLineHeight: 16
        )
    )

    @Test("nine applications take two rows of seven")
    func rows() {
        #expect(SpringboardFolderMetrics(metrics: Self.mainMetrics, applicationCount: 9, isDragging: false).rowCount == 2)
        #expect(SpringboardFolderMetrics(metrics: Self.mainMetrics, applicationCount: 80, isDragging: false).rowCount == 5)
    }

    @Test("a full last row gets an empty row while dragging")
    func extraRowWhileDragging() {
        #expect(SpringboardFolderMetrics(metrics: Self.mainMetrics, applicationCount: 14, isDragging: true).rowCount == 3)
        #expect(SpringboardFolderMetrics(metrics: Self.mainMetrics, applicationCount: 14, isDragging: false).rowCount == 2)
    }

    @Test("the folder is centred in the springboard and grows 30 points downwards")
    func folderFrame() {
        let folderMetrics = SpringboardFolderMetrics(metrics: Self.mainMetrics, applicationCount: 9, isDragging: false)
        #expect(folderMetrics.folderFrame == CGRect(x: 0, y: 287, width: 1470, height: 441))
    }

    @Test("pages, panel and dots match the worked example")
    func panelAndPages() {
        let folderMetrics = SpringboardFolderMetrics(metrics: Self.mainMetrics, applicationCount: 9, isDragging: false)
        #expect(folderMetrics.pageFrame(at: 0) == CGRect(x: 148, y: 0, width: 1174, height: 302))
        #expect(folderMetrics.scrollFrame == CGRect(x: 0, y: 34, width: 1470, height: 411))
        #expect(folderMetrics.panelFrame == CGRect(x: 128, y: 0, width: 1214, height: 376))
        #expect(folderMetrics.pagerControlFrame == CGRect(x: 0, y: 14, width: 1470, height: 15))
    }

    @Test("the title sits in the band above the panel")
    func title() {
        let folderMetrics = SpringboardFolderMetrics(metrics: Self.mainMetrics, applicationCount: 9, isDragging: false)
        let titleFrame = folderMetrics.titleFrame(forTitleSize: CGSize(width: 100, height: 41))
        #expect(titleFrame == CGRect(x: 685, y: 388, width: 100, height: 41))
    }

    @Test(
        "the folder icon's square is inset by size",
        arguments: [(48.0, 5.0), (64.0, 7.0), (104.0, 10.0), (128.0, 12.0)]
    )
    func backdropInset(iconSide: Double, expectedInset: Double) {
        #expect(SpringboardFolderMetrics.folderBackdropInset(forIconSide: CGFloat(iconSide)) == CGFloat(expectedInset))
    }

    @Test("a 104-point folder icon has an 84-point square and an 8-point thumbnail inset")
    func folderIcon() {
        let backdropSide = 104 - 2 * SpringboardFolderMetrics.folderBackdropInset(forIconSide: 104)
        #expect(backdropSide == 84)
        #expect(SpringboardFolderMetrics.thumbnailGridInset(forBackdropSide: backdropSide) == 8)
    }
}
