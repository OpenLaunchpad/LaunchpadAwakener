import AppKit
import LaunchpadAwakenerSpringboardCore
import OSToolbox

/// The springboard's window in the standalone app: borderless, over the whole main display at the level
/// macOS 15's Launchpad window took (27, above the menu bar's 24 and the Dock's 20), on every Space and
/// over full-screen applications. The Dock cannot be raised above it from another process, so it is
/// covered.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "StandaloneSpringboardWindow")
@MainActor
final class StandaloneSpringboardWindow: SpringboardWindow {
    /// macOS 15's `-[Springboard prepareForEnterAnimation]` put its window here.
    static let windowLevel = NSWindow.Level(rawValue: 27)

    let displayBounds: CGRect
    let backingScaleFactor: CGFloat
    let rootLayer: CALayer
    private(set) var isOrderedIn = false
    private let window: StandaloneFullScreenWindow
    private let contentView: StandaloneSpringboardContentView

    init?(displayIdentifier: CGDirectDisplayID) {
        guard let screen = StandaloneEnvironment.screen(forDisplay: displayIdentifier) else { return nil }
        displayBounds = CGDisplayBounds(displayIdentifier)
        backingScaleFactor = screen.backingScaleFactor
        window = StandaloneFullScreenWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = Self.windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        window.setFrame(screen.frame, display: false)
        // A layer-hosting view: the springboard owns the whole layer tree, as in the Dock's window.
        let contentView = StandaloneSpringboardContentView(frame: CGRect(origin: .zero, size: screen.frame.size))
        rootLayer = CALayer()
        rootLayer.frame = contentView.bounds
        contentView.layer = rootLayer
        contentView.wantsLayer = true
        window.contentView = contentView
        self.contentView = contentView
        window.eventHandler = { [contentView] event in
            guard let cgEvent = event.cgEvent else { return false }
            // The input methods take the key from here, when the springboard offers it to them.
            contentView.currentEvent = event
            defer { contentView.currentEvent = nil }
            return SpringboardController.shared.handle(SpringboardInputEvent(event: cgEvent, eventType: cgEvent.type.rawValue))
        }
    }

    /// Converts a global point (top-left origin) into the window's coordinates.
    func windowPoint(fromGlobalPoint globalPoint: CGPoint) -> CGPoint {
        CGPoint(x: globalPoint.x - displayBounds.minX, y: globalPoint.y - displayBounds.minY)
    }

    func orderIn() {
        guard !isOrderedIn else { return }
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(contentView)
        StandaloneInputMethod.shared.contentView = contentView
        isOrderedIn = true
        StandaloneWatchdog.shared.watch(windowNumber: window.windowNumber)
        #log(.info, "Ordered in window \(self.window.windowNumber, privacy: .public) at level \(self.window.level.rawValue, privacy: .public): key \(self.window.isKeyWindow, privacy: .public), app active \(NSApp.isActive, privacy: .public)")
    }

    /// Hands the keyboard back to the application that had it as the exit animation starts, as 15 did;
    /// the window itself stays until the animation ends.
    func releaseKeyFocus() {
        guard NSApp.isActive else { return }
        NSApp.deactivate()
    }

    func orderOut() {
        guard isOrderedIn else { return }
        StandaloneWatchdog.shared.stopWatching(windowNumber: window.windowNumber)
        if StandaloneInputMethod.shared.contentView === contentView {
            contentView.inputContext?.discardMarkedText()
            StandaloneInputMethod.shared.contentView = nil
        }
        window.orderOut(nil)
        isOrderedIn = false
    }

    /// What the window would show as, for the self-check: frame, level and how it behaves across Spaces.
    var selfCheckDescription: String {
        "frame \(NSStringFromRect(window.frame)), level \(window.level.rawValue), joins all Spaces \(window.collectionBehavior.contains(.canJoinAllSpaces)), over full-screen applications \(window.collectionBehavior.contains(.fullScreenAuxiliary)), scale \(backingScaleFactor)"
    }
}

/// A borderless window that can take the keyboard and gives every event to the springboard first.
final class StandaloneFullScreenWindow: NSWindow {
    /// Returns whether the springboard took the event; the ones it did not take go on as usual.
    var eventHandler: ((NSEvent) -> Bool)?

    override var canBecomeKey: Bool {
        true
    }

    override var canBecomeMain: Bool {
        true
    }

    override func sendEvent(_ event: NSEvent) {
        if let eventHandler, eventHandler(event) {
            return
        }
        super.sendEvent(event)
    }
}
