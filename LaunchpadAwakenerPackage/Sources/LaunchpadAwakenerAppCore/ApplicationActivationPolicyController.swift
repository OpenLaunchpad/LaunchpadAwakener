import AppKit
import Foundation
import Observation

/// Keeps the Dock icon tied to whether a window is actually open.
///
/// A utility that lives in the menu bar should not leave a Dock icon behind after its window is
/// closed — a Dock tile is a handle for an app you are working in, and once the window is gone
/// there is nothing to click it for. But dropping the Dock icon permanently (`LSUIElement` on its
/// own) costs the window its menu bar, and with it ⌘W, Cut/Copy/Paste, and everything else people
/// expect a window to have.
///
/// So the policy follows the windows: `.regular` while one is open, `.accessory` once none are.
/// `LSUIElement` in the app's Info.plist makes the launched-with-no-window case correct from the
/// first frame rather than flashing a Dock icon and taking it away again.
///
/// Driven from the window's own `onAppear` / `onDisappear` rather than from
/// `NSWindow.willCloseNotification`. A closing window is still in `NSApplication.windows` and still
/// reports `isVisible` when that notification fires, so anything counting windows there has to
/// either exclude the closing one by identity or wait a run-loop turn and hope. SwiftUI already
/// knows exactly when the window went away.
///
/// The menu bar item is what reopens the window, so an app using this must offer one — otherwise
/// closing the window makes the app unreachable.
@MainActor
@Observable
public final class ApplicationActivationPolicyController {
    private var openWindowCount = 0

    public init() {}

    /// Call from the window's `onAppear`.
    public func windowDidAppear() {
        openWindowCount += 1
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    /// Call from the window's `onDisappear`.
    public func windowDidDisappear() {
        openWindowCount = max(0, openWindowCount - 1)
        guard openWindowCount == 0 else { return }
        NSApplication.shared.setActivationPolicy(.accessory)
    }

    /// Switches to `.regular` and brings the app forward, before a window is opened.
    ///
    /// Opening a window from the menu bar while the app is an accessory does not focus it: an
    /// accessory app is not in the activation order, so the window would appear behind whatever the
    /// user was looking at. Doing this first means it arrives in front.
    ///
    /// Static because the caller is a menu bar item with no reason to hold the controller, and this
    /// touches nothing but `NSApplication`.
    public static func activateForWindowPresentation() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }
}
