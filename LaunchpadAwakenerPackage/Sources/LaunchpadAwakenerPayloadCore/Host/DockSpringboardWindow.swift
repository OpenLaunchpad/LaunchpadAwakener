import CoreGraphics
import Foundation
import OSToolbox
import QuartzCore
import LaunchpadAwakenerSpringboardCore

/// The full-screen Dock window the springboard draws in, shown the way macOS 15 showed Launchpad.
///
/// macOS 15's `-[Springboard init]` created a `WALayerKitWindow` on the Dock's own connection at the
/// Dock's level, and `-[Springboard prepareForEnterAnimation]` (0x10002D57C in 15.5) then moved it to
/// level 27 — above the menu bar — raised the Dock's windows to 29 so the Dock stays usable on top,
/// and took key focus without activating any application. ``orderOut()`` undoes all of it.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "SpringboardWindow")
@MainActor
final class DockSpringboardWindow: SpringboardWindow {
    static let dockWindowLevel: Int32 = 20
    static let springboardWindowLevel: Int32 = 27
    static let raisedDockWindowLevel: Int32 = 29
    /// The tags macOS 15's `-[Springboard init]` passed.
    static let windowTags: UInt64 = 1024

    let displayIdentifier: CGDirectDisplayID
    /// Global coordinates with a top-left origin.
    let displayBounds: CGRect
    let backingScaleFactor: CGFloat
    let rootLayer: CALayer

    private let window: DockLayerKitWindowImplementation
    private let connectionIdentifier: UInt32
    private let windowIdentifier: UInt32
    private var raisedDockWindowIdentifiers: [UInt32] = []
    private var hasKeyFocus = false

    private(set) var isOrderedIn = false

    init?(displayIdentifier: CGDirectDisplayID) {
        guard let connectionIdentifier = SkyLightBridge.mainConnectionIdentifier else { return nil }
        let displayBounds = CGDisplayBounds(displayIdentifier)
        guard
            let windowObject = DockHostInterface.makeLayerKitWindow(
                frame: displayBounds,
                connectionIdentifier: connectionIdentifier,
                displayIdentifier: displayIdentifier,
                tags: Self.windowTags,
                level: Self.dockWindowLevel
            ),
            let window = DockLayerKitWindowImplementation(windowObject),
            let rootLayer = window.layer,
            let windowIdentifier = window.wid
        else { return nil }

        self.displayIdentifier = displayIdentifier
        self.displayBounds = displayBounds
        self.backingScaleFactor = Self.backingScaleFactor(of: displayIdentifier)
        self.rootLayer = rootLayer
        self.window = window
        self.connectionIdentifier = connectionIdentifier
        self.windowIdentifier = windowIdentifier
    }

    /// Converts a global point (top-left origin) into the window's coordinates.
    func windowPoint(fromGlobalPoint globalPoint: CGPoint) -> CGPoint {
        CGPoint(x: globalPoint.x - displayBounds.minX, y: globalPoint.y - displayBounds.minY)
    }

    func orderIn() {
        guard !isOrderedIn else { return }
        let levelResult = SkyLightBridge.setWindowLevel(
            Self.springboardWindowLevel,
            ofWindowWithIdentifier: windowIdentifier,
            onConnection: connectionIdentifier
        )
        raiseDockWindows()
        window.order(1, otherWindow: 0)
        let keyFocusResult = SkyLightBridge.stealKeyFocus(onConnection: connectionIdentifier)
        hasKeyFocus = keyFocusResult == 0
        isOrderedIn = true
        #log(.info, "Ordered in window \(self.windowIdentifier, privacy: .public): level result \(levelResult ?? -1, privacy: .public), key focus result \(keyFocusResult ?? -1, privacy: .public), raised \(self.raisedDockWindowIdentifiers.count, privacy: .public) Dock window(s)")
    }

    /// Gives key focus back without closing, as 15 did the moment its exit animation started. The Dock never
    /// becomes the active application, so the keyboard goes back to the one that is, launched or not.
    func releaseKeyFocus(returningToPreviousApplication: Bool) {
        guard hasKeyFocus else { return }
        SkyLightBridge.releaseKeyFocus(onConnection: connectionIdentifier)
        hasKeyFocus = false
    }

    func orderOut() {
        guard isOrderedIn else { return }
        window.order(0, otherWindow: 0)
        releaseKeyFocus(returningToPreviousApplication: true)
        for raisedDockWindowIdentifier in raisedDockWindowIdentifiers {
            SkyLightBridge.setWindowLevel(
                Self.dockWindowLevel,
                ofWindowWithIdentifier: raisedDockWindowIdentifier,
                onConnection: connectionIdentifier
            )
        }
        raisedDockWindowIdentifiers = []
        isOrderedIn = false
    }

    /// Raises the Dock's own on-screen windows at the Dock level above the springboard, the way
    /// macOS 15 kept the Dock visible and usable on top of Launchpad.
    private func raiseDockWindows() {
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        guard let windowDescriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            #log(.error, "Could not list windows")
            return
        }
        raisedDockWindowIdentifiers = windowDescriptions.compactMap { windowDescription -> UInt32? in
            guard
                (windowDescription[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                (windowDescription[kCGWindowLayer as String] as? NSNumber)?.int32Value == Self.dockWindowLevel,
                let windowNumber = windowDescription[kCGWindowNumber as String] as? NSNumber,
                windowNumber.uint32Value != windowIdentifier
            else { return nil }
            return windowNumber.uint32Value
        }
        for raisedDockWindowIdentifier in raisedDockWindowIdentifiers {
            SkyLightBridge.setWindowLevel(
                Self.raisedDockWindowLevel,
                ofWindowWithIdentifier: raisedDockWindowIdentifier,
                onConnection: connectionIdentifier
            )
        }
    }

    private static func backingScaleFactor(of displayIdentifier: CGDirectDisplayID) -> CGFloat {
        guard let displayMode = CGDisplayCopyDisplayMode(displayIdentifier), displayMode.width > 0 else { return 2 }
        return CGFloat(displayMode.pixelWidth) / CGFloat(displayMode.width)
    }
}
