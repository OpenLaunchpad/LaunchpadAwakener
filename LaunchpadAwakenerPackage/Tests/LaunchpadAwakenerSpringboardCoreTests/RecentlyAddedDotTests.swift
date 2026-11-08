import CoreGraphics
@testable import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// Expected values follow `-[ECSBItemLayer layout]` and `-[ECFlagLayer layout]` (15.5 `0x100020A14`,
/// `0x1000E812C`): a 193-point cell, labels at most 181 wide, a 15-point flag beside 23-point labels.
@Suite("The blue dot beside a new application's name")
@MainActor
struct RecentlyAddedDotTests {
    @Test("without a dot the title is centred and at most the maximum width")
    func withoutDot() {
        #expect(SpringboardItemLayer.labelPlacement(preferredWidth: 100, cellWidth: 193, maximumWidth: 181, flagSide: nil) == (100, 0, false))
        #expect(SpringboardItemLayer.labelPlacement(preferredWidth: 200, cellWidth: 193, maximumWidth: 181, flagSide: nil) == (181, 0, false))
    }

    @Test("a title that leaves room for the dot stays centred, the dot hanging off its left")
    func dotFits() {
        #expect(SpringboardItemLayer.labelPlacement(preferredWidth: 165, cellWidth: 193, maximumWidth: 181, flagSide: 15) == (165, 0, false))
    }

    @Test("a longer title shrinks, moves right by half the flag and turns left-aligned")
    func dotDoesNotFit() {
        #expect(SpringboardItemLayer.labelPlacement(preferredWidth: 166, cellWidth: 193, maximumWidth: 181, flagSide: 15) == (165, 8, true))
    }

    @Test("the dot is 9 points round, centred in the flag before the title and 5 points up")
    func dotFrame() throws {
        let labelLayer = SpringboardLabelLayer()
        labelLayer.setRecentlyAddedDot(isShown: true, flagSide: 15)
        let dotLayer = try #require(labelLayer.sublayers?.last)
        #expect(dotLayer.frame == CGRect(x: -11, y: 8, width: 9, height: 9))
        #expect(dotLayer.cornerRadius == 4.5)

        labelLayer.setRecentlyAddedDot(isShown: false, flagSide: 15)
        #expect(!labelLayer.showsRecentlyAddedDot)
    }
}
