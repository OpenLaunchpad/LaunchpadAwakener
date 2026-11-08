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

/// What a key does over the pages in front, by `-[ECSBPager navigate:withEvent:]` (15.5 `0x10005A534`)
/// and, in an open folder, `-[ECSBGroupPager navigate:withEvent:]` (`0x10006A6BC`) and `keyDown:`
/// (`0x10006A608`).
@Suite("Keys over the pages by macOS 15's rules")
struct SpringboardKeyCommandTests {
    private static func command(
        _ keyCode: Int64,
        command hasCommand: Bool = false,
        inFolder isInFolder: Bool = false,
        selection hasSelection: Bool = true,
        canTurnBackward: Bool = true,
        canTurnForward: Bool = true
    ) -> SpringboardKeyCommand? {
        SpringboardKeyCommand(
            keyCode: keyCode,
            hasCommand: hasCommand,
            isInFolder: isInFolder,
            hasSelection: hasSelection,
            canTurnBackward: canTurnBackward,
            canTurnForward: canTurnForward
        )
    }

    @Test("arrows move the selection on the main pages and in a folder alike", arguments: [false, true])
    func arrows(isInFolder: Bool) {
        #expect(Self.command(SpringboardKeyCode.leftArrow, inFolder: isInFolder) == .navigate(.left))
        #expect(Self.command(SpringboardKeyCode.rightArrow, inFolder: isInFolder) == .navigate(.right))
        #expect(Self.command(SpringboardKeyCode.upArrow, inFolder: isInFolder) == .navigate(.up))
        #expect(Self.command(SpringboardKeyCode.downArrow, inFolder: isInFolder) == .navigate(.down))
    }

    @Test("Command-arrows turn the page, and act as plain arrows where there is no page to turn to", arguments: [false, true])
    func commandArrows(isInFolder: Bool) {
        #expect(Self.command(SpringboardKeyCode.leftArrow, command: true, inFolder: isInFolder) == .turnPage(by: -1))
        #expect(Self.command(SpringboardKeyCode.rightArrow, command: true, inFolder: isInFolder) == .turnPage(by: 1))
        #expect(Self.command(SpringboardKeyCode.leftArrow, command: true, inFolder: isInFolder, canTurnBackward: false) == .navigate(.left))
        #expect(Self.command(SpringboardKeyCode.rightArrow, command: true, inFolder: isInFolder, canTurnForward: false) == .navigate(.right))
    }

    @Test("Return performs the selected item", arguments: [SpringboardKeyCode.returnKey, SpringboardKeyCode.keypadEnter])
    func returnKey(keyCode: Int64) {
        #expect(Self.command(keyCode) == .performSelectedItem(opensFoldersOnly: false))
        #expect(Self.command(keyCode, inFolder: true) == .performSelectedItem(opensFoldersOnly: false))
    }

    @Test("Command-Down opens a selected folder on the main pages; a folder holds none, so there it is Down")
    func commandDown() {
        #expect(Self.command(SpringboardKeyCode.downArrow, command: true) == .performSelectedItem(opensFoldersOnly: true))
        #expect(Self.command(SpringboardKeyCode.downArrow, command: true, inFolder: true) == .navigate(.down))
    }

    @Test("Command-Up closes a folder with a selection and selects the folder; otherwise it is Up")
    func commandUp() {
        #expect(Self.command(SpringboardKeyCode.upArrow, command: true, inFolder: true) == .closeFolderSelectingIt)
        #expect(Self.command(SpringboardKeyCode.upArrow, command: true, inFolder: true, selection: false) == .navigate(.up))
        #expect(Self.command(SpringboardKeyCode.upArrow, command: true) == .navigate(.up))
    }

    @Test("other keys are not navigation")
    func otherKeys() {
        #expect(Self.command(SpringboardKeyCode.tab) == nil)
        #expect(Self.command(SpringboardKeyCode.delete, inFolder: true) == nil)
    }
}

@Suite("Dragging by macOS 15's rules")
struct SpringboardDraggingTests {
    private static let cellSize = CGSize(width: 100, height: 100)

    @Test("the cell under the point, counted row by row from the top left")
    func plainHit() {
        let index = SpringboardDragging.itemIndex(at: CGPoint(x: 250, y: 150), cellSize: Self.cellSize, columnCount: 7, itemCount: 35, currentIndex: nil, usesHysteresis: false)
        #expect(index == 9)
    }

    @Test("with hysteresis the item stays until the point is half a cell beyond its cell")
    func hysteresisKeepsTheCurrentCell() {
        let nearby = SpringboardDragging.itemIndex(at: CGPoint(x: 140, y: 50), cellSize: Self.cellSize, columnCount: 7, itemCount: 35, currentIndex: 0, usesHysteresis: true)
        let farEnough = SpringboardDragging.itemIndex(at: CGPoint(x: 160, y: 50), cellSize: Self.cellSize, columnCount: 7, itemCount: 35, currentIndex: 0, usesHysteresis: true)
        #expect(nearby == 0)
        #expect(farEnough == 1)
    }

    @Test("past the last item the last cell is the answer")
    func pastTheLastItem() {
        let index = SpringboardDragging.itemIndex(at: CGPoint(x: 650, y: 450), cellSize: Self.cellSize, columnCount: 7, itemCount: 10, currentIndex: nil, usesHysteresis: false)
        #expect(index == 9)
    }

    @Test("75 points per second is where icons start responding")
    func speed() {
        let slow = SpringboardDragging.speed(from: .zero, to: CGPoint(x: 7, y: 0), elapsedNanoseconds: 100_000_000)
        let fast = SpringboardDragging.speed(from: .zero, to: CGPoint(x: 8, y: 0), elapsedNanoseconds: 100_000_000)
        #expect(slow < SpringboardDragging.settlingSpeedThreshold)
        #expect(fast > SpringboardDragging.settlingSpeedThreshold)
    }
}
