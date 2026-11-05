import CoreGraphics
import LaunchpadAwakenerPayloadCore
import Testing

/// The expected values are the worked example of the macOS 15.5 specification
/// (`/Volumes/RE/Dock/15.5/Notes/LaunchpadMainInterface.md`, section 1.4), computed by hand from the
/// disassembled formulas: a 1470 × 956 point screen, the Dock at the bottom 59 points thick, 7 × 5.
@Suite("Springboard geometry")
struct SpringboardMetricsTests {
    private static func metrics(notchHeight: CGFloat = 0, screenWidth: CGFloat = 1470, orientation: DockOrientation = .bottom) -> SpringboardMetrics {
        SpringboardMetrics(
            SpringboardMetrics.Input(
                screenSize: CGSize(width: screenWidth, height: 956),
                dockOrientation: orientation,
                dockThickness: 59,
                notchHeight: notchHeight,
                rowCount: 5,
                columnCount: 7,
                zoomStyle: 0,
                labelLineHeight: 16
            )
        )
    }

    @Test("the springboard starts 30 points above the Dock")
    func springboardFrame() {
        #expect(Self.metrics().springboardFrame == CGRect(x: 0, y: 89, width: 1470, height: 867))
    }

    @Test("margins widen by a fifth of the zoom factor on a 1470-point screen")
    func margins() {
        let metrics = Self.metrics()
        #expect(metrics.zoomFactor == 0.2)
        #expect([metrics.leftMargin, metrics.rightMargin, metrics.topMargin, metrics.bottomMargin] == [148, 148, 35, 44])
    }

    @Test("pages, cells and icons match the worked example")
    func pageCellAndIcon() {
        let metrics = Self.metrics()
        #expect(metrics.pageSize == CGSize(width: 1174, height: 758))
        #expect(metrics.cellSize == CGSize(width: 167, height: 151))
        #expect(metrics.iconSide == 104)
        #expect(metrics.labelHeight == 23)
        #expect(metrics.cellBottomPadding == 19)
        #expect(metrics.labelMaximumWidth == 155)
    }

    @Test("a 32-point notch shrinks the rows and the icons")
    func notch() {
        let metrics = Self.metrics(notchHeight: 32)
        #expect(metrics.pageSize.height == 726)
        #expect(metrics.cellSize.height == 145)
        #expect(metrics.iconSide == 96)
    }

    @Test("the search field spans 610 to 860 across and 25 to 50 down from the top of the screen")
    func searchField() {
        let metrics = Self.metrics()
        let fieldInScreen = metrics.searchFieldFrame.offsetBy(dx: metrics.springboardFrame.minX, dy: metrics.springboardFrame.minY)
        #expect(fieldInScreen.minX == 610)
        #expect(fieldInScreen.maxX == 860)
        #expect(956 - fieldInScreen.maxY == 25)
        #expect(956 - fieldInScreen.minY == 50)
    }

    @Test("the page dots are centred 110 points above the bottom of the screen")
    func pagerDots() {
        let metrics = Self.metrics()
        let indicator = metrics.pagerIndicatorFrame(at: 0, pageCount: 3)
        let dot = metrics.pagerDotFrame(inIndicatorFrame: indicator)
        #expect(metrics.springboardFrame.minY + metrics.pagerControlFrame.minY + dot.midY == 110)
        #expect(indicator.minX == 707)
        #expect(metrics.pagerIndicatorFrame(at: 1, pageCount: 3).minX == 727)
    }

    @Test("the first row sits at the top of the page")
    func cellOrder() {
        let metrics = Self.metrics()
        #expect(metrics.cellFrame(at: 0) == CGRect(x: 0, y: 607, width: 167, height: 151))
        #expect(metrics.cellFrame(at: 8) == CGRect(x: 167, y: 456, width: 167, height: 151))
    }

    @Test("pages sit one springboard width apart")
    func pageSpacing() {
        let metrics = Self.metrics()
        // Spelled as CGFloat: inside #expect an untyped arithmetic literal becomes an Int.
        #expect(metrics.pageFrame(at: 2).minX == CGFloat(148 + 2 * 1470))
        #expect(metrics.scrollValue(forPageAt: 2) == CGFloat(2 * 1470))
    }

    @Test(
        "icon sides snap down to multiples of 8 between 20 and 128",
        arguments: [(104.0, 104.0), (111.9, 104.0), (300.0, 128.0), (12.0, 20.0), (-5.0, 20.0)]
    )
    func iconSnapping(rawSide: Double, expectedSide: Double) {
        #expect(SpringboardMetrics.snappedIconSide(CGFloat(rawSide)) == CGFloat(expectedSide))
    }

    @Test("a single row of search results is centred")
    func centredSearchRow() {
        let metrics = Self.metrics()
        #expect(metrics.centeredRowOffset(forItemCount: 2) == 420)
        #expect(metrics.centeredRowOffset(forItemCount: 3) == 336)
        #expect(metrics.centeredRowOffset(forItemCount: 7) == 0)
    }
}
