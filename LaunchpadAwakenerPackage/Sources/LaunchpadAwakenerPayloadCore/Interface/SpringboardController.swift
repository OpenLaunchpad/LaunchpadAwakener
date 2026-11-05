import CoreGraphics
import Foundation
import OSToolbox

/// Shows, hides and drives the springboard; the counterpart of macOS 15's `Springboard`.
///
/// A full-screen window that keeps input and never lets go is what made the earlier macOS 26 attempt
/// unrecoverable, so three ways out are always available: Escape, the kill-switch file, and — in
/// development builds — closing by itself after `idleDismissInterval` without input.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "SpringboardController")
@MainActor
final class SpringboardController {
    static let shared = SpringboardController()

    /// While this file exists, every entry falls back to the system's Apps and a showing springboard
    /// closes on its next event. Creating it over ssh is the way out when the screen is unusable.
    nonisolated static let killSwitchPath = "/tmp/LaunchpadAwakener.disabled"

    nonisolated static var isDisabledByKillSwitch: Bool {
        FileManager.default.fileExists(atPath: killSwitchPath)
    }

    #if DEBUG
    private static let idleDismissInterval: TimeInterval = 20
    #endif

    private var window: SpringboardWindow?
    private var content: TransitionalSpringboardContent?
    /// The latest layout from ``LaunchpadServices/library``; empty until the library has loaded.
    private var layout: LaunchpadLayout = .empty
    /// Bumped on every input and every hide, so a stale idle timer cannot hide a later showing.
    private var idleGeneration = 0

    var isVisible: Bool {
        window?.isOrderedIn ?? false
    }

    func toggle(reason: String) {
        if isVisible {
            hide(reason: reason)
        } else {
            show(reason: reason)
        }
    }

    func show(reason: String) {
        guard !isVisible else { return }
        guard let newWindow = SpringboardWindow(displayIdentifier: CGMainDisplayID()) else {
            #log(.error, "Could not create the springboard window")
            return
        }
        let newContent = TransitionalSpringboardContent(
            layout: layout,
            rootLayer: newWindow.rootLayer,
            size: newWindow.displayBounds.size,
            backingScaleFactor: newWindow.backingScaleFactor
        )
        window = newWindow
        content = newContent
        newWindow.orderIn()
        restartIdleTimer()
        #log(.info, "Shown (\(reason, privacy: .public)): \(newContent.itemCount, privacy: .public) first-page item(s), \(newContent.applicationCount, privacy: .public) application(s)")
    }

    /// Takes a new layout from the library. A showing springboard keeps the layout it opened with.
    func updateLayout(_ newLayout: LaunchpadLayout) {
        layout = newLayout
    }

    func hide(reason: String) {
        guard let currentWindow = window else { return }
        idleGeneration += 1
        currentWindow.orderOut()
        content?.removeFromRootLayer()
        content = nil
        window = nil
        #log(.info, "Hidden (\(reason, privacy: .public))")
    }

    // MARK: - Input

    /// Called for every event the Dock receives. Returns whether the springboard consumed it; anything
    /// not consumed goes on to the Dock as usual.
    func handle(_ inputEvent: SpringboardInputEvent) -> Bool {
        guard isVisible, let window, let content else { return false }
        if Self.isDisabledByKillSwitch {
            hide(reason: "kill switch")
            return false
        }

        switch inputEvent.kind {
        case let .keyDown(keyCode, characters, _):
            restartIdleTimer()
            perform(content.handleKeyDown(keyCode: keyCode, characters: characters, hasCommandModifier: inputEvent.hasCommandModifier))
            return true
        case .keyUp, .modifiersChanged:
            return true
        case .mouseDown(.left, _):
            // Clicks on the Dock stay the Dock's, as they did over macOS 15's Launchpad.
            guard !isInsideDockBar(inputEvent.location) else { return false }
            restartIdleTimer()
            perform(content.handleClick(atWindowPoint: window.windowPoint(fromGlobalPoint: inputEvent.location)))
            return true
        case .mouseUp(.left):
            guard isInsideDockBar(inputEvent.location) else { return true }
            // Whatever the click on the Dock opens takes key focus, so close afterwards, as macOS 15's
            // Launchpad closed when something was opened from the Dock.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    SpringboardController.shared.hide(reason: "clicked the Dock")
                }
            }
            return false
        case .mouseDown, .mouseUp, .mouseDragged:
            return !isInsideDockBar(inputEvent.location)
        case .mouseMoved, .scrollWheel, .other:
            return false
        }
    }

    private func perform(_ action: SpringboardContentAction) {
        switch action {
        case .none:
            break
        case .dismiss(let reason):
            hide(reason: reason)
        case let .launch(bundleIdentifier, title):
            // Give key focus back before the application activates, so it becomes key as usual.
            hide(reason: "launching \(title)")
            ApplicationLauncher.launchApplication(withBundleIdentifier: bundleIdentifier)
        }
    }

    private func isInsideDockBar(_ location: CGPoint) -> Bool {
        DockBarReference.currentBarRect?.contains(location) ?? false
    }

    private func restartIdleTimer() {
        idleGeneration += 1
        #if DEBUG
        let scheduledGeneration = idleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDismissInterval) {
            MainActor.assumeIsolated {
                let controller = SpringboardController.shared
                guard controller.idleGeneration == scheduledGeneration else { return }
                controller.hide(reason: "idle")
            }
        }
        #endif
    }
}
