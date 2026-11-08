import AppKit
@testable import LaunchpadAwakenerSpringboardCore
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

/// Out of the Dock, the springboard still reads 15's resources from the Dock's bundle.
@Suite("Standalone resources")
@MainActor
struct StandaloneResourceTests {
    @Test("the standalone host reads its resources from the system's Dock.app")
    func resourceBundleIsTheDock() throws {
        let resourceBundle = try #require(StandaloneSpringboardHost.shared.resourceBundle)
        #expect(resourceBundle.bundleIdentifier == "com.apple.dock")
        #expect(SpringboardTextures.image(named: "ectl_search_background", scale: 2, in: resourceBundle) != nil)
    }
}
