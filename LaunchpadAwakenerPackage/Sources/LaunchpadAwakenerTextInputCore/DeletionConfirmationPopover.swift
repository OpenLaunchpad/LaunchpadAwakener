import AppKit
import LaunchpadAwakenerShared
import OSToolbox

/// The confirmation macOS 15 asked for before deleting an application from Launchpad: an `NSPopover` under
/// the icon, shown by the Dock's `com.apple.dock.ecap` service
/// (`-[ECAPHelperDelegate _handleShowPanelMessage:forPeer:]`, ecap 15.5 `0x100000FC0`).
///
/// As in 15, the popover's own window goes on screen, raised over Launchpad's window; nothing in the Dock
/// shows it, and clicks on its buttons come straight here from the window server. It hangs from an empty
/// view in a transparent window of the view's size, put on the icon's centre. The buttons only report which
/// was pressed and leave the popover up: the Dock closes it, for a button, for Return or Escape, which it
/// reads itself, and when Launchpad goes.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DeletionConfirmationPopover")
@MainActor
final class DeletionConfirmationPopover: NSObject, NSPopoverDelegate {
    /// Above Launchpad's window, 27, and the Dock's windows raised over it, 29: the level 15's service gave
    /// the popover's window (ecap `0x1000010E8`).
    static let windowLevel = NSWindow.Level(rawValue: 106)
    /// 15's anchor, an empty 16 × 16 view whose window the Dock moved onto the icon's centre.
    static let anchorSide: CGFloat = 16
    /// The popover points at a 20 × 20 square on the icon's centre.
    static let positioningSide: CGFloat = 20

    /// Called with the button pressed.
    var answerHandler: ((DeletionConfirmationAnswer) -> Void)?

    private var anchorWindow: NSWindow?
    /// The popover on screen, until it is dismissed.
    private var popover: NSPopover?

    /// Shows the confirmation under the icon, replacing any still up. Returns whether it is on screen.
    func present(_ configuration: DeletionConfirmationConfiguration) -> Bool {
        dismiss(animated: false)
        let contentViewController = DeletionConfirmationViewController()
        contentViewController.configure(with: configuration)
        contentViewController.answerHandler = { [weak self] answer in
            self?.answerHandler?(answer)
        }

        let anchorWindow = anchorWindow ?? Self.makeAnchorWindow()
        self.anchorWindow = anchorWindow
        let iconCenter = CGPoint(x: configuration.iconCenterX, y: configuration.iconCenterY)
        let zeroScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        anchorWindow.setFrame(Self.anchorFrame(forIconCenter: iconCenter, zeroScreenHeight: zeroScreenHeight), display: false)
        anchorWindow.orderFrontRegardless()
        guard let anchorView = anchorWindow.contentView else { return false }

        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.contentViewController = contentViewController
        popover.delegate = self
        popover.show(relativeTo: Self.positioningRect, of: anchorView, preferredEdge: .minY)
        guard let popoverWindow = contentViewController.view.window, popoverWindow.isVisible else {
            #log(.error, "The deletion confirmation did not come on screen")
            popover.animates = false
            popover.close()
            anchorWindow.orderOut(nil)
            return false
        }
        popoverWindow.level = Self.windowLevel
        popoverWindow.collectionBehavior.formUnion([.canJoinAllSpaces, .fullScreenAuxiliary])
        // A button in a window that is not key would take the first click only to make it key. The process
        // never takes the real key focus (`TextInputApplication`), so this leaves the Dock's keyboard alone.
        if !popoverWindow.isKeyWindow {
            popoverWindow.makeKey()
        }
        self.popover = popover
        #log(.info, "Showing the deletion confirmation under \(iconCenter.x, privacy: .public), \(iconCenter.y, privacy: .public): popover window \(popoverWindow.windowNumber, privacy: .public) at \(NSStringFromRect(popoverWindow.frame), privacy: .public), key \(popoverWindow.isKeyWindow, privacy: .public), application active \(NSApp.isActive, privacy: .public)")
        return true
    }

    /// Closes the confirmation, fading as 15's did; the anchor goes once the popover has.
    func dismiss() {
        dismiss(animated: true)
    }

    private func dismiss(animated: Bool) {
        guard let popover else { return }
        self.popover = nil
        popover.animates = animated
        popover.close()
        if !animated {
            anchorWindow?.orderOut(nil)
        }
        #log(.info, "Closed the deletion confirmation")
    }

    func popoverDidClose(_ notification: Notification) {
        // A confirmation shown since hangs from the same anchor.
        guard popover == nil else { return }
        anchorWindow?.orderOut(nil)
    }

    // MARK: - The anchor

    /// The anchor's frame for an icon centred at `iconCenter`, a point from the top left of the main display:
    /// centred on it, in AppKit's coordinates from the bottom left of the main display.
    static func anchorFrame(forIconCenter iconCenter: CGPoint, zeroScreenHeight: CGFloat) -> NSRect {
        NSRect(
            x: iconCenter.x - anchorSide / 2,
            y: zeroScreenHeight - iconCenter.y - anchorSide / 2,
            width: anchorSide,
            height: anchorSide
        )
    }

    /// The square the popover points at, in the anchor view: 20 × 20 on its centre, which 15 got by
    /// insetting the 16 × 16 view by −2.
    static var positioningRect: NSRect {
        let inset = (anchorSide - positioningSide) / 2
        return NSRect(x: inset, y: inset, width: positioningSide, height: positioningSide)
    }

    /// A window that shows nothing and lets every click through: transparent, without a shadow, at the
    /// popover's level so that a popover AppKit keeps above its anchor stays above Launchpad too.
    ///
    /// It is a nonactivating panel because the popover's window copies that from its anchor's when it is
    /// shown (`-[NSPopover showRelativeToRect:ofView:preferredEdge:]`, 26.6 `0x184C67550`). In a process
    /// that is not the active application only a nonactivating window becomes key
    /// (`-[NSWindow _changeKeyAndMainLimitedOK:]`, `0x184AE7E54`), through `_stealKeyFocusWithOptions:`, which
    /// ``TextInputApplication`` answers without taking the keyboard; and only the key window draws Delete as
    /// the default button (`-[NSButtonBezelConfiguration shouldDrawAsDefaultButton]`, `0x1850BFA9C`). 15's
    /// anchor, the Dock tile's mini view window, answered `_isNonactivatingPanel` with YES for the same
    /// reason.
    static func makeAnchorWindow() -> NSWindow {
        let frame = NSRect(x: 0, y: 0, width: anchorSide, height: anchorSide)
        let window = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        // The process counts as active only while the popover is key; a panel would hide when that ends.
        window.hidesOnDeactivate = false
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.ignoresMouseEvents = true
        window.level = windowLevel
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.contentView = NSView(frame: frame)
        return window
    }
}
