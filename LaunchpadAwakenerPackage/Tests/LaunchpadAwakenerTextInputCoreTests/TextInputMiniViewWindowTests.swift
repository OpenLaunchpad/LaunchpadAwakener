import AppKit
@testable import LaunchpadAwakenerTextInputCore
import Testing

/// The window the helper's field lives in goes on screen, at Launchpad's level, once the Dock tile's mini
/// view is shown. Only the Dock's `CALayerHost` is meant to show the field; anything the window drew there
/// itself would stay over an open folder's panel, and keep the last search over other applications after
/// the springboard has gone.
@Suite("The mini view window on screen")
@MainActor
struct TextInputMiniViewWindowTests {
    @Test("the window shows nothing on screen")
    func windowIsInvisibleOnScreen() {
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 200, height: 25), styleMask: [.borderless], backing: .buffered, defer: true)

        TextInputService.makeInvisibleOnScreen(window)

        #expect(window.alphaValue == 0)
    }
}
