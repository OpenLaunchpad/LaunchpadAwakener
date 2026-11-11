import CoreGraphics
import Foundation
import OSToolbox
import QuartzCore
import LaunchpadAwakenerSpringboardCore

/// The transparent window above the Dock that carries an icon dragged onto it.
///
/// macOS 15 carried every dragged icon in a `WALayerKitWindow` of its own, covering the screen at the
/// dragging level, 500 (`-[ECSBDragCapture _beginDragOfItemLayerWithEvent:itemFrame:]`, 15.5 `0x1000B4B98`),
/// so the icon stayed in sight over the Dock. The springboard's own window is at 27 and the Dock's are
/// raised to 29 above it, so the icon rides here while it is on the Dock. The window is the Dock's, like
/// the springboard's: the pointer's events reach the same event handler whichever of the two it is over,
/// and the window never takes the keyboard.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockDragWindow")
@MainActor
final class DockDragWindow: SpringboardDragWindow {
    /// `kCGDraggingWindowLevel`, where 15's drag window was.
    static let draggingWindowLevel: Int32 = 500

    let rootLayer: CALayer

    private let window: DockLayerKitWindowImplementation
    private let connectionIdentifier: UInt32
    private let windowIdentifier: UInt32
    private var isOrderedIn = false

    init?(displayIdentifier: CGDirectDisplayID) {
        guard let connectionIdentifier = SkyLightBridge.mainConnectionIdentifier else { return nil }
        guard
            let windowObject = DockHostInterface.makeLayerKitWindow(
                frame: CGDisplayBounds(displayIdentifier),
                connectionIdentifier: connectionIdentifier,
                displayIdentifier: displayIdentifier,
                tags: DockSpringboardWindow.windowTags,
                level: DockSpringboardWindow.dockWindowLevel
            ),
            let window = DockLayerKitWindowImplementation(windowObject),
            let rootLayer = window.layer,
            let windowIdentifier = window.wid
        else { return nil }
        self.rootLayer = rootLayer
        self.window = window
        self.connectionIdentifier = connectionIdentifier
        self.windowIdentifier = windowIdentifier
    }

    func orderIn() {
        guard !isOrderedIn else { return }
        let levelResult = SkyLightBridge.setWindowLevel(
            Self.draggingWindowLevel,
            ofWindowWithIdentifier: windowIdentifier,
            onConnection: connectionIdentifier
        )
        window.order(1, otherWindow: 0)
        isOrderedIn = true
        #log(.info, "Ordered in the drag window \(self.windowIdentifier, privacy: .public): level result \(levelResult ?? -1, privacy: .public)")
    }

    func orderOut() {
        guard isOrderedIn else { return }
        window.order(0, otherWindow: 0)
        isOrderedIn = false
    }
}
