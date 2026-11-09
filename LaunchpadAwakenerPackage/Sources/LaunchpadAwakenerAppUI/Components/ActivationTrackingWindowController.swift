import AppKit
import LaunchpadAwakenerAppCore
import UIFoundation

/// A window controller that tells the activation policy controller when its window comes and goes, so
/// that the Dock icon shows exactly while one of the app's windows is open.
///
/// Each controller tracks its own window and reports each change once. Counting `NSApp.windows` in
/// `windowWillClose` would not work: the closing window is still listed there.
class ActivationTrackingWindowController: XiblessWindowController<NSWindow>, NSWindowDelegate {
    private let activationPolicyController: ApplicationActivationPolicyController
    private var isOnScreen = false

    init(window: @autoclosure @escaping () -> NSWindow, activationPolicyController: ApplicationActivationPolicyController) {
        self.activationPolicyController = activationPolicyController
        super.init(windowGenerator: window())
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        contentWindow.delegate = self
        // The controller keeps the window: closing it hides it, and the next showing brings back the same
        // window where the user left it, as SwiftUI's window did.
        contentWindow.isReleasedWhenClosed = false
        // Launching never restores it; the app decides at launch whether it opens.
        contentWindow.isRestorable = false
    }

    /// Brings the window forward, ahead of whatever the user was looking at.
    ///
    /// The app is an accessory while no window is open, and an accessory is not in the activation order:
    /// without switching first, the window would open behind the frontmost application.
    func present() {
        ApplicationActivationPolicyController.activateForWindowPresentation()
        showWindow(nil)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        guard !isOnScreen else { return }
        isOnScreen = true
        activationPolicyController.windowDidAppear()
    }

    func windowWillClose(_ notification: Notification) {
        guard isOnScreen else { return }
        isOnScreen = false
        activationPolicyController.windowDidDisappear()
    }
}
