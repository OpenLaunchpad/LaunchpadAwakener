import AppKit
import LaunchpadAwakenerSpringboardCore
import Testing

/// GitHub's runners have a window server, but whether they let a test process change window tags has not been
/// seen; this pins a fact of the machines the Dock runs on, so it runs where windows can be made and off CI.
private let isContinuousIntegration = ProcessInfo.processInfo.environment["GITHUB_ACTIONS"] != nil

/// The window-server functions the springboard's window uses to let the pointer through while the Dock drags one
/// of its icons. They are resolved by name at run time, so a system without them would only show up in the Dock.
///
/// What the tags do is not read back here: `CGSGetWindowTags` reports neither of the two bits for a window that
/// was never ordered in — not after the bridge set them, not after AppKit's own `ignoresMouseEvents` did — so the
/// effect is checked by dragging a Dock icon out over the springboard on a test machine.
@Suite("Window tags that let the pointer through")
@MainActor
struct SkyLightWindowTagTests {
    @Test(
        "the bridge switches a real window both ways",
        .enabled(if: CGMainDisplayID() != kCGNullDirectDisplay && !isContinuousIntegration)
    )
    func switchesBothWays() throws {
        // Never ordered in: the window exists in the window server without ever showing.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let connectionIdentifier = try #require(SkyLightBridge.mainConnectionIdentifier)
        let windowIdentifier = try #require(UInt32(exactly: window.windowNumber))

        #expect(SkyLightBridge.setIgnoresPointerEvents(true, ofWindowWithIdentifier: windowIdentifier, onConnection: connectionIdentifier) == 0)
        #expect(SkyLightBridge.setIgnoresPointerEvents(false, ofWindowWithIdentifier: windowIdentifier, onConnection: connectionIdentifier) == 0)
    }

    @Test("the two tags are the ones AppKit switches for ignoresMouseEvents")
    func tagBits() {
        // AppKit 27.2 `_NSSetIgnoresMouseEvents` sets window-manager tag 9 to ignore and 10 to take, clearing the
        // other; `_NSCGSWindowTagsFromWMTags` turns tag n into bit n.
        #expect(SkyLightBridge.ignoresPointerEventsWindowTag == 0x200)
        #expect(SkyLightBridge.takesPointerEventsWindowTag == 0x400)
    }
}
