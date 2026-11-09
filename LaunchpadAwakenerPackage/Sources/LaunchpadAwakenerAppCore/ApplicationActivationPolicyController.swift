import AppKit
import Foundation
import Observation
import OSToolbox

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
/// Driven by each window controller reporting its own window — once when it is shown, once from
/// `windowWillClose(_:)` — rather than by counting `NSApplication.windows`. A closing window is still
/// in `NSApplication.windows` and still reports `isVisible` when `willClose` fires, so anything
/// counting windows there has to either exclude the closing one by identity or wait a run-loop turn
/// and hope.
///
/// The menu bar item is what reopens the window, so an app using this must offer one — otherwise
/// closing the window makes the app unreachable.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "ApplicationActivationPolicyController")
@MainActor
@Observable
public final class ApplicationActivationPolicyController {
    private var openWindowCount = 0

    public init() {}

    /// Call when one of the app's windows comes on screen.
    public func windowDidAppear() {
        openWindowCount += 1
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
        #if DEBUG
        // Where the window landed against the screen's visible area, so a window reaching behind the
        // Dock or the menu bar shows in the log of the test Mac without anyone looking at its screen.
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            Self.logWindowGeometry()
        }
        #endif
    }

    private static func logWindowGeometry() {
        for window in NSApplication.shared.windows where window.isVisible && window.styleMask.contains(.titled) {
            let visibleFrame = window.screen?.visibleFrame ?? .zero
            let fitsVisibleFrame = visibleFrame.contains(window.frame)
            #log(.info, "Window \(window.title, privacy: .public) frame \(NSStringFromRect(window.frame), privacy: .public), screen visible frame \(NSStringFromRect(visibleFrame), privacy: .public), fits: \(fitsVisibleFrame, privacy: .public)")
        }
    }

    /// Call when one of the app's windows closes.
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
