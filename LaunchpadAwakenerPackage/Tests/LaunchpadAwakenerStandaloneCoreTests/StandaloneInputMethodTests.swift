import AppKit
@testable import LaunchpadAwakenerStandaloneCore
import Testing

/// The standalone window's side of the system's input methods.
@Suite("Standalone input methods")
@MainActor
struct StandaloneInputMethodTests {
    @Test("input methods are told the springboard window's level, so their candidates show above it")
    func contentViewReportsItsWindowLevel() {
        // Never ordered in: the window only carries the level.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: true)
        window.level = StandaloneSpringboardWindow.windowLevel
        let contentView = StandaloneSpringboardContentView(frame: window.contentLayoutRect)
        window.contentView = contentView
        #expect(contentView.windowLevel() == 27)
    }
}
