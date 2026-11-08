import CoreGraphics
@testable import LaunchpadAwakenerPayloadCore
import Testing

/// Where the text input helper's field goes in the search field: the text area, after the loupe and before
/// the clear button, taken from the field's frame rather than from layers that may be scaled at the time.
@Suite("The hosted search field's place")
struct SpringboardHostedFieldTests {
    @Test("the hosted field fills the text area of a 250 × 25 field: from 26 points in, 200 wide")
    func textAreaOfField() {
        let textArea = SpringboardSearchFieldLayer.hostedTextAreaFrame(inFieldFrame: CGRect(x: 610, y: 900, width: 250, height: 25))

        #expect(textArea == CGRect(x: 636, y: 900, width: 200, height: 25))
    }

    @Test("the size the helper is asked for follows the field's size")
    func textAreaSize() {
        #expect(SpringboardSearchFieldLayer.hostedTextAreaSize(forFieldSize: CGSize(width: 250, height: 25)) == CGSize(width: 200, height: 25))
    }
}
