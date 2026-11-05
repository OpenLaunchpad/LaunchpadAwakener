import CoreGraphics
import LaunchpadAwakenerPayloadCore
import Testing

/// Expected values follow section 5 of the macOS 15.5 specification.
@Suite("Paging by macOS 15's rules")
struct SpringboardPagingTests {
    @Test("beyond either end the content follows at a quarter")
    func rubberBand() {
        #expect(SpringboardPaging.rubberBandedScrollValue(-100, pageWidth: 1000, pageCount: 3) == -25)
        #expect(SpringboardPaging.rubberBandedScrollValue(2100, pageWidth: 1000, pageCount: 3) == 2025)
        #expect(SpringboardPaging.rubberBandedScrollValue(1500, pageWidth: 1000, pageCount: 3) == 1500)
    }

    @Test("a slow release springs back to the current page")
    func slowReleaseSpringsBack() {
        // 100 points over one second is 1.0 in 15's units, below the threshold of 2.0.
        let pageIndex = SpringboardPaging.settledPageIndex(currentPageIndex: 1, pageCount: 3, startScrollValue: 1000, endScrollValue: 1100, elapsedNanoseconds: 1_000_000_000)
        #expect(pageIndex == 1)
    }

    @Test("a quick release turns one page in the direction moved")
    func quickReleaseTurnsAPage() {
        // 300 points over a second is 3.0, above the threshold.
        let forward = SpringboardPaging.settledPageIndex(currentPageIndex: 1, pageCount: 3, startScrollValue: 1000, endScrollValue: 1300, elapsedNanoseconds: 1_000_000_000)
        let backward = SpringboardPaging.settledPageIndex(currentPageIndex: 1, pageCount: 3, startScrollValue: 1000, endScrollValue: 700, elapsedNanoseconds: 1_000_000_000)
        #expect(forward == 2)
        #expect(backward == 0)
    }

    @Test("a quick release past the last page stays on it")
    func quickReleasePastTheEnd() {
        let pageIndex = SpringboardPaging.settledPageIndex(currentPageIndex: 2, pageCount: 3, startScrollValue: 2000, endScrollValue: 2400, elapsedNanoseconds: 1_000_000_000)
        #expect(pageIndex == 2)
    }

    @Test("any net wheel movement turns exactly one page")
    func wheelTurnsOnePage() {
        #expect(SpringboardPaging.wheelSettledPageIndex(currentPageIndex: 0, pageCount: 3, startScrollValue: 0, endScrollValue: 4) == 1)
        #expect(SpringboardPaging.wheelSettledPageIndex(currentPageIndex: 1, pageCount: 3, startScrollValue: 1000, endScrollValue: 1000) == 1)
    }

    @Test("the larger axis scrolls, reversed by default, vertical on a tie")
    func scrollDistance() {
        #expect(SpringboardPaging.scrollDistance(horizontalLineDelta: -3, verticalLineDelta: 1, reversesScrollGesture: true) == 6)
        #expect(SpringboardPaging.scrollDistance(horizontalLineDelta: 2, verticalLineDelta: -2, reversesScrollGesture: false) == -4)
    }
}

@Suite("Arrow keys by macOS 15's rules")
struct SpringboardNavigationTests {
    @Test("with nothing selected, down and right pick the first item, up and left the last")
    func firstSelection() {
        #expect(SpringboardNavigation.selectedIndex(after: .down, from: nil, itemCount: 33, columnCount: 7) == 0)
        #expect(SpringboardNavigation.selectedIndex(after: .left, from: nil, itemCount: 33, columnCount: 7) == 32)
    }

    @Test("left and right step through reading order and stop at the ends of the page")
    func horizontalSteps() {
        #expect(SpringboardNavigation.selectedIndex(after: .right, from: 6, itemCount: 33, columnCount: 7) == 7)
        #expect(SpringboardNavigation.selectedIndex(after: .right, from: 32, itemCount: 33, columnCount: 7) == 32)
        #expect(SpringboardNavigation.selectedIndex(after: .left, from: 0, itemCount: 33, columnCount: 7) == 0)
    }

    @Test("up and down move a whole row and stay put where there is none")
    func verticalSteps() {
        #expect(SpringboardNavigation.selectedIndex(after: .down, from: 25, itemCount: 33, columnCount: 7) == 32)
        #expect(SpringboardNavigation.selectedIndex(after: .down, from: 27, itemCount: 33, columnCount: 7) == 27)
        #expect(SpringboardNavigation.selectedIndex(after: .up, from: 3, itemCount: 33, columnCount: 7) == 3)
    }
}
