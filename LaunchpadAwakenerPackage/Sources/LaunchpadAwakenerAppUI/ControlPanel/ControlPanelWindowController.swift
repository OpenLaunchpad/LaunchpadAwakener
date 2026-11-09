import AppKit
import LaunchpadAwakenerAppCore
import LaunchpadAwakenerSharedUI

/// The control panel's window: 520 points wide, as tall as its content up to the screen's visible area.
///
/// It is sized once, the first time it opens. After that it keeps the size and place the user left it
/// at for as long as the app runs; a new launch starts from the content again.
final class ControlPanelWindowController: ActivationTrackingWindowController {
    /// Kept free between the window's content and the edges of the screen's visible area: the title
    /// bar, which the content height does not include, and a margin.
    private static let screenEdgeAllowance: CGFloat = 72

    private static let minimumContentHeight: CGFloat = 320

    private let controlPanelViewController: ControlPanelViewController
    private var hasBeenSized = false

    init(controlPanelViewController: ControlPanelViewController, activationPolicyController: ApplicationActivationPolicyController) {
        self.controlPanelViewController = controlPanelViewController
        super.init(
            window: NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: ControlPanelViewController.width, height: Self.minimumContentHeight),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: true
            ),
            activationPolicyController: activationPolicyController
        )
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        contentWindow.title = "LaunchpadAwakener"
        contentWindow.contentViewController = controlPanelViewController
        // Fixed width; the height may grow past the content, where the form has room to spare.
        contentWindow.contentMinSize = NSSize(width: ControlPanelViewController.width, height: Self.minimumContentHeight)
        contentWindow.contentMaxSize = NSSize(width: ControlPanelViewController.width, height: CGFloat.greatestFiniteMagnitude)
        contentWindow.collectionBehavior.insert(.fullScreenNone)
        // Listed in the Window menu by its own command, which works whether or not the window is open.
        contentWindow.isExcludedFromWindowsMenu = true
    }

    override func showWindow(_ sender: Any?) {
        // Reading `window` loads it and runs `windowDidLoad`, which installs the content to measure.
        if !hasBeenSized, window != nil {
            hasBeenSized = true
            sizeToContent()
        }
        super.showWindow(sender)
    }

    private func sizeToContent() {
        let screen = contentWindow.screen ?? NSScreen.main
        let placement = ContentSizedWindowPlacement(
            fittingContentHeight: controlPanelViewController.fittingContentHeight(forWidth: ControlPanelViewController.width),
            minimumContentHeight: Self.minimumContentHeight,
            visibleFrameHeight: screen?.visibleFrame.height ?? .greatestFiniteMagnitude,
            screenEdgeAllowance: Self.screenEdgeAllowance
        )
        contentWindow.setContentSize(NSSize(width: ControlPanelViewController.width, height: placement.contentHeight))
        contentWindow.center()
    }
}
