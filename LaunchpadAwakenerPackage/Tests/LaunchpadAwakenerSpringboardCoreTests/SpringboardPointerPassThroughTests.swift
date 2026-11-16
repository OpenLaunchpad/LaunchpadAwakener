import CoreGraphics
import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// The springboard's window lets the pointer through for exactly as long as the Dock is handling a drag that
/// began on it, so an icon dragged out of the Dock is removed instead of going back, and the window takes the
/// pointer again as soon as the drag is over.
@Suite("Letting the pointer through while the Dock drags")
@MainActor
struct SpringboardPointerPassThroughTests {
    final class RecordingWindow: SpringboardWindow {
        let displayBounds = CGRect(x: 0, y: 0, width: 1470, height: 956)
        let backingScaleFactor: CGFloat = 2
        let rootLayer = CALayer()
        let isOrderedIn = true
        private(set) var passThroughChanges: [Bool] = []

        func windowPoint(fromGlobalPoint globalPoint: CGPoint) -> CGPoint { globalPoint }
        func orderIn() {}
        func releaseKeyFocus(returningToPreviousApplication: Bool) {}
        func orderOut() {}
        func setPassesPointerEventsThrough(_ passesThrough: Bool) {
            passThroughChanges.append(passesThrough)
        }
    }

    @Test("an event the Dock handles at once lets the pointer through and takes it back")
    func singleEvent() {
        let window = RecordingWindow()
        let passThrough = SpringboardPointerPassThrough()
        passThrough.begin(with: window)
        #expect(window.passThroughChanges == [true])
        passThrough.end()
        #expect(window.passThroughChanges == [true, false])
    }

    @Test("the events of a drag, handled inside the event that started it, leave the window to the outermost")
    func nestedEvents() {
        let window = RecordingWindow()
        let passThrough = SpringboardPointerPassThrough()
        passThrough.begin(with: window)
        for _ in 0..<3 {
            passThrough.begin(with: window)
            passThrough.end()
        }
        #expect(window.passThroughChanges == [true])
        passThrough.end()
        #expect(window.passThroughChanges == [true, false])
    }

    @Test("a springboard shown anew during the drag is left alone, and the first window gets the pointer back")
    func windowReplacedDuringDrag() {
        let firstWindow = RecordingWindow()
        let laterWindow = RecordingWindow()
        let passThrough = SpringboardPointerPassThrough()
        passThrough.begin(with: firstWindow)
        passThrough.begin(with: laterWindow)
        passThrough.end()
        passThrough.end()
        #expect(firstWindow.passThroughChanges == [true, false])
        #expect(laterWindow.passThroughChanges.isEmpty)
    }

    @Test("with no window up nothing is switched, and the next drag still is")
    func noWindow() {
        let window = RecordingWindow()
        let passThrough = SpringboardPointerPassThrough()
        passThrough.begin(with: nil)
        passThrough.end()
        passThrough.begin(with: window)
        passThrough.end()
        #expect(window.passThroughChanges == [true, false])
    }

    @Test("an end without a begin changes nothing and leaves the count balanced")
    func unbalancedEnd() {
        let window = RecordingWindow()
        let passThrough = SpringboardPointerPassThrough()
        passThrough.end()
        passThrough.begin(with: window)
        passThrough.end()
        #expect(window.passThroughChanges == [true, false])
    }
}
