import CoreGraphics
import Foundation
import OSToolbox
import QuartzCore

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

    /// 15's launch animation: a copy of the icon grows to twice its size and fades from 0.9 to 0.1
    /// (`-[Springboard performOpenAnimationForRunnable:withImage:atFrame:toFrame:]`, `0x1000918C8`).
    private static let launchAnimationDuration: CFTimeInterval = 0.25

    private var window: SpringboardWindow?
    private var interface: SpringboardInterface?
    /// The latest layout from ``LaunchpadServices/library``; empty until the library has loaded.
    private var layout: LaunchpadLayout = .empty
    /// Bumped on every input and every hide, so a stale idle timer cannot hide a later showing.
    private var idleGeneration = 0
    /// The window an application was just launched from; input is ignored until it closes.
    private weak var launchingWindow: SpringboardWindow?

    private init() {
        SpringboardIconProvider.shared.iconDidBecomeAvailable = { bundleURL in
            SpringboardController.shared.interface?.iconDidBecomeAvailable(forApplicationAt: bundleURL)
        }
    }

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
        SpringboardIconProvider.shared.refreshIconStyle()
        let metrics = Self.metrics(forScreenSize: newWindow.displayBounds.size)
        let newInterface = SpringboardInterface(
            layout: layout,
            metrics: metrics,
            scale: newWindow.backingScaleFactor,
            rootLayer: newWindow.rootLayer,
            applyEdit: { edit in
                Task {
                    await LaunchpadServices.library.apply(edit)
                }
            }
        )
        window = newWindow
        interface = newInterface
        newWindow.orderIn()
        restartIdleTimer()
        #log(.info, "Shown (\(reason, privacy: .public)): \(newInterface.geometryDescription, privacy: .public)")
    }

    func hide(reason: String) {
        guard let currentWindow = window else { return }
        idleGeneration += 1
        currentWindow.orderOut()
        interface?.tearDown()
        interface = nil
        window = nil
        #log(.info, "Hidden (\(reason, privacy: .public))")
    }

    /// Takes a new layout from the library — after an edit, or after applications came or went — and
    /// renders its icons ahead of time. A showing springboard takes it once nothing is moving.
    func updateLayout(_ newLayout: LaunchpadLayout) {
        layout = newLayout
        interface?.replaceLayout(newLayout)
        let displayIdentifier = CGMainDisplayID()
        let metrics = Self.metrics(forScreenSize: CGDisplayBounds(displayIdentifier).size)
        let scale = Self.backingScaleFactor(of: displayIdentifier)
        let iconProvider = SpringboardIconProvider.shared
        iconProvider.refreshIconStyle()
        let bundleURLs = newLayout.applications.compactMap(\.bundleURL)
        iconProvider.prefetchIcons(forApplicationsAt: bundleURLs, pointSide: metrics.iconSide, scale: scale)
        #log(.info, "Prefetching \(bundleURLs.count, privacy: .public) icon(s) at \(Int(metrics.iconSide), privacy: .public) points")
        #if DEBUG
        SpringboardSelfCheck.runOnce(layout: newLayout, metrics: metrics, scale: scale)
        #endif
    }

    private static func metrics(forScreenSize screenSize: CGSize) -> SpringboardMetrics {
        SpringboardMetrics(
            SpringboardMetrics.Input(
                screenSize: screenSize,
                dockOrientation: DockEnvironment.dockOrientation,
                dockThickness: DockEnvironment.dockThickness,
                notchHeight: DockEnvironment.notchHeight,
                rowCount: SpringboardPreferences.rowCount,
                columnCount: SpringboardPreferences.columnCount,
                zoomStyle: SpringboardPreferences.zoomStyle,
                labelLineHeight: SpringboardTypography.lineHeight(of: SpringboardTypography.labelFont)
            )
        )
    }

    private static func backingScaleFactor(of displayIdentifier: CGDirectDisplayID) -> CGFloat {
        guard let displayMode = CGDisplayCopyDisplayMode(displayIdentifier), displayMode.width > 0 else { return 2 }
        return CGFloat(displayMode.pixelWidth) / CGFloat(displayMode.width)
    }

    // MARK: - Input

    /// Called for every event the Dock receives. Returns whether the springboard consumed it; anything
    /// not consumed goes on to the Dock as usual.
    func handle(_ inputEvent: SpringboardInputEvent) -> Bool {
        guard isVisible, let window, let interface else { return false }
        if Self.isDisabledByKillSwitch {
            hide(reason: "kill switch")
            return false
        }

        guard launchingWindow !== window else {
            // The launch animation is playing; the window closes when it ends.
            return !isInsideDockBar(inputEvent.location)
        }

        let windowPoint = window.windowPoint(fromGlobalPoint: inputEvent.location)
        let containerPoint = CGPoint(x: windowPoint.x, y: window.displayBounds.height - windowPoint.y)
        switch inputEvent.kind {
        case let .keyDown(keyCode, characters, _):
            restartIdleTimer()
            perform(interface.handleKeyDown(keyCode: keyCode, characters: characters, modifierFlags: inputEvent.modifierFlags))
            return true
        case .keyUp, .modifiersChanged:
            return true
        case .mouseDown(.left, _):
            // Clicks on the Dock stay the Dock's, as they did over macOS 15's Launchpad.
            guard !isInsideDockBar(inputEvent.location) else { return false }
            restartIdleTimer()
            perform(interface.handleMouseDown(at: containerPoint, timestamp: inputEvent.timestamp))
            return true
        case .mouseDragged(.left):
            restartIdleTimer()
            perform(interface.handleMouseDragged(to: containerPoint, timestamp: inputEvent.timestamp))
            return true
        case .mouseUp(.left):
            guard interface.dragSession != nil || !isInsideDockBar(inputEvent.location) else {
                // Whatever the click on the Dock opens takes key focus, so close afterwards, as
                // macOS 15's Launchpad closed when something was opened from the Dock.
                DispatchQueue.main.async {
                    MainActor.assumeIsolated {
                        SpringboardController.shared.hide(reason: "clicked the Dock")
                    }
                }
                return false
            }
            perform(interface.handleMouseUp(at: containerPoint, timestamp: inputEvent.timestamp))
            return true
        case .scrollWheel(let scrollWheel):
            guard !isInsideDockBar(inputEvent.location) else { return false }
            restartIdleTimer()
            perform(interface.handleScrollWheel(scrollWheel, timestamp: inputEvent.timestamp))
            return true
        case .mouseDown, .mouseUp, .mouseDragged:
            return !isInsideDockBar(inputEvent.location)
        case .mouseMoved, .other:
            return false
        }
    }

    private func perform(_ action: SpringboardInterface.Action) {
        switch action {
        case .none:
            break
        case .dismiss(let reason):
            hide(reason: reason)
        case let .launch(application, iconFrame, iconImage):
            launch(application, iconFrame: iconFrame, iconImage: iconImage)
        }
    }

    private func launch(_ application: LaunchpadApplication, iconFrame: CGRect, iconImage: Any?) {
        if let bundleURL = application.bundleURL {
            ApplicationLauncher.launchApplication(at: bundleURL)
        } else {
            ApplicationLauncher.launchApplication(withBundleIdentifier: application.bundleIdentifier)
        }
        guard let interface, iconImage != nil, !iconFrame.isEmpty else {
            hide(reason: "launching \(application.title)")
            return
        }

        let launchingIconLayer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        launchingIconLayer.frame = iconFrame
        launchingIconLayer.contents = iconImage
        launchingIconLayer.contentsGravity = .resizeAspect
        launchingIconLayer.opacity = 0.1
        launchingIconLayer.transform = CATransform3DMakeScale(2, 2, 1)
        interface.containerLayer.addSublayer(launchingIconLayer)
        CATransaction.commit()

        let scaleAnimation = CABasicAnimation(keyPath: "transform.scale")
        scaleAnimation.fromValue = 1
        scaleAnimation.toValue = 2
        let opacityAnimation = CABasicAnimation(keyPath: "opacity")
        opacityAnimation.fromValue = 0.9
        opacityAnimation.toValue = 0.1
        let launchAnimation = CAAnimationGroup()
        launchAnimation.animations = [scaleAnimation, opacityAnimation]
        launchAnimation.duration = Self.launchAnimationDuration
        launchAnimation.timingFunction = CAMediaTimingFunction(name: .easeOut)
        launchingIconLayer.add(launchAnimation, forKey: "launch")

        launchingWindow = window
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.launchAnimationDuration) {
            MainActor.assumeIsolated {
                let controller = SpringboardController.shared
                guard let launchingWindow = controller.launchingWindow, launchingWindow === controller.window else { return }
                controller.hide(reason: "launched \(application.title)")
            }
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
