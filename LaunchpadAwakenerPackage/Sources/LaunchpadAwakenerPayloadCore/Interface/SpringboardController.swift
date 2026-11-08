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

    /// The springboard on screen and taking input; nil once it starts to hide.
    private var window: SpringboardWindow?
    private var interface: SpringboardInterface?
    /// A springboard fading out: no longer taking input, removed once its exit animation ends.
    private var hidingWindow: SpringboardWindow?
    private var hidingInterface: SpringboardInterface?
    /// The latest layout from ``LaunchpadServices/library``; empty until the library has loaded.
    private var layout: LaunchpadLayout = .empty
    /// Bumped on every input and every hide, so a stale idle timer cannot hide a later showing.
    private var idleGeneration = 0
    /// Where the springboard was when it last hid; the next showing opens there.
    private var lastPosition = SpringboardPosition.firstPage
    /// When a click on the Dock last closed the springboard, until the next request to open Apps;
    /// see ``SpringboardEntry``.
    private var lastDockClickDismissal: ContinuousClock.Instant?

    /// A pinch in progress: whether it opens, and how visible it has made the springboard.
    private var pinch: (isOpening: Bool, visibility: Double)?
    private var visibilitySpring: SpringboardVisibilitySpring?
    private var springTimer: DispatchSourceTimer?

    private init() {
        SpringboardIconProvider.shared.iconDidBecomeAvailable = { bundleURL in
            SpringboardController.shared.interface?.iconDidBecomeAvailable(forApplicationAt: bundleURL)
        }
    }

    var isVisible: Bool {
        window?.isOrderedIn ?? false
    }

    /// Answers a request to open Apps: the Launchpad key, a hot corner, the Apps icon in the Dock.
    func toggle(reason: String) {
        let sinceDockClickDismissal = lastDockClickDismissal.map { ContinuousClock.now - $0 }
        lastDockClickDismissal = nil
        switch SpringboardEntry.response(isVisible: isVisible, sinceDockClickDismissal: sinceDockClickDismissal) {
        case .show:
            show(reason: reason)
        case .hide:
            hide(reason: reason)
        case .stayHidden:
            #log(.info, "Stays hidden (\(reason, privacy: .public)): the click on the Dock that closed it was on Apps")
        }
    }

    // MARK: - Showing and hiding

    /// Shows the springboard; `animated` false leaves it fully transparent for a pinch to reveal.
    func show(reason: String, animated: Bool = true) {
        guard !isVisible else { return }
        finishHiding()
        let displayIdentifier = CGMainDisplayID()
        guard let newWindow = SpringboardWindow(displayIdentifier: displayIdentifier) else {
            #log(.error, "Could not create the springboard window")
            return
        }
        SpringboardIconProvider.shared.refreshIconStyle()
        clearRecentlyAddedMarksOfLaunchedApplications()
        let metrics = Self.metrics(forScreenSize: newWindow.displayBounds.size)
        let backgroundStyle = SpringboardPreferences.backgroundStyle
        // 15 captured the wallpaper afresh each time it opened.
        let wallpaperImage = backgroundStyle == .wallpaper ? WallpaperSnapshot.captureWallpaperImage(onDisplay: displayIdentifier) : nil
        let newInterface = SpringboardInterface(
            layout: layout,
            metrics: metrics,
            scale: newWindow.backingScaleFactor,
            rootLayer: newWindow.rootLayer,
            backgroundStyle: backgroundStyle,
            wallpaperImage: wallpaperImage,
            position: lastPosition,
            applyEdit: { edit in
                Task {
                    await LaunchpadServices.library.apply(edit)
                }
            }
        )
        newInterface.setVisibility(0)
        window = newWindow
        interface = newInterface
        newWindow.orderIn()
        if animated {
            newInterface.animateEntrance(duration: SpringboardPreferences.showAnimationDuration)
        }
        restartIdleTimer()
        let displayBounds = newWindow.displayBounds
        // The container is y-up from the display's bottom left; the screen is y-down from the top left.
        newInterface.screenTopLeft = { rectInContainer in
            CGPoint(x: displayBounds.minX + rectInContainer.minX, y: displayBounds.minY + displayBounds.height - rectInContainer.maxY)
        }
        newInterface.beginRemoteSearchField()
        let backgroundDescription = switch backgroundStyle {
        case .wallpaper:
            wallpaperImage.map { "the wallpaper, \($0.width)×\($0.height) pixels" } ?? "15's gradient"
        case .glass:
            newInterface.background?.isGlass == true ? "the Dock's glass, variant \(SpringboardPreferences.glassVariant)" : "the stand-in blur"
        }
        #log(.info, "Shown (\(reason, privacy: .public)) on \(newInterface.position.description, privacy: .public) over \(backgroundDescription, privacy: .public): \(newInterface.geometryDescription, privacy: .public)")
        #if DEBUG
        SpringboardSelfCheck.logShownBackground(of: newInterface, rootLayer: newWindow.rootLayer)
        #endif
    }

    /// Hides the springboard. Input goes back at once, as in 15; the window leaves when the exit
    /// animation ends.
    func hide(reason: String, animated: Bool = true) {
        guard let currentWindow = window, let currentInterface = interface else { return }
        window = nil
        interface = nil
        idleGeneration += 1
        stopPinch()
        currentInterface.prepareForHiding()
        // After the preparation: a drag it cancels may take a folder it had opened away with it.
        lastPosition = currentInterface.position
        currentWindow.releaseKeyFocus()
        hidingWindow = currentWindow
        hidingInterface = currentInterface
        if animated {
            currentInterface.animateExit(duration: SpringboardPreferences.hideAnimationDuration) { [weak self] in
                guard let self, self.hidingWindow === currentWindow else { return }
                self.finishHiding()
            }
        } else {
            finishHiding()
        }
        #log(.info, "Hidden (\(reason, privacy: .public)) on \(self.lastPosition.description, privacy: .public)")
    }

    /// Removes a springboard that is fading out, now.
    private func finishHiding() {
        guard let hidingWindow else { return }
        hidingWindow.orderOut()
        hidingInterface?.tearDown()
        self.hidingWindow = nil
        hidingInterface = nil
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
        switch inputEvent.kind {
        case .dockSwipe(let dockSwipe):
            handlePinch(dockSwipe)
            return false
        case .systemGestureCancelled:
            endPinch(isCancelled: true, intendedProgress: 0, velocity: 0)
            return false
        default:
            break
        }

        guard isVisible, let window, let interface else { return false }
        if Self.isDisabledByKillSwitch {
            hide(reason: "kill switch", animated: false)
            return false
        }

        let windowPoint = window.windowPoint(fromGlobalPoint: inputEvent.location)
        let containerPoint = CGPoint(x: windowPoint.x, y: window.displayBounds.height - windowPoint.y)
        switch inputEvent.kind {
        case let .keyDown(keyCode, characters, _):
            restartIdleTimer()
            perform(interface.handleKeyDown(keyCode: keyCode, characters: characters, modifierFlags: inputEvent.modifierFlags))
            return true
        case .keyUp:
            interface.handleKeyUp()
            return true
        case .modifiersChanged:
            interface.handleModifiersChanged(inputEvent.modifierFlags)
            return true
        case let .mouseDown(.left, clickCount):
            // Clicks on the Dock stay the Dock's, as they did over macOS 15's Launchpad.
            guard !isInsideDockBar(inputEvent.location) else { return false }
            restartIdleTimer()
            perform(interface.handleMouseDown(at: containerPoint, timestamp: inputEvent.timestamp, modifierFlags: inputEvent.modifierFlags, clickCount: clickCount))
            return true
        case .mouseDragged(.left):
            restartIdleTimer()
            perform(interface.handleMouseDragged(to: containerPoint, timestamp: inputEvent.timestamp))
            return true
        case .mouseUp(.left):
            guard interface.dragSession != nil || !isInsideDockBar(inputEvent.location) else {
                // Whatever the click on the Dock opens takes key focus, so close afterwards, as
                // macOS 15's Launchpad closed when something was opened from the Dock. A click on Apps
                // asks to open Apps a moment later; that request must not open the springboard again.
                lastDockClickDismissal = .now
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
        case .navigationSwipe(let navigationSwipe):
            #if DEBUG
            #log(.info, "Navigation swipe: motion \(navigationSwipe.motion, privacy: .public), direction flag \(navigationSwipe.directionFlag, privacy: .public)")
            #endif
            restartIdleTimer()
            perform(interface.handleNavigationSwipe(navigationSwipe))
            // 15's pager turned the page and still answered that it had not handled the gesture.
            return false
        case .mouseDown, .mouseUp, .mouseDragged:
            return !isInsideDockBar(inputEvent.location)
        case .mouseMoved, .other, .dockSwipe, .systemGestureCancelled:
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

    /// Drops the blue dot of every marked application launched from elsewhere since it came. Spotlight is
    /// asked in the background, never on the way to showing; the library publishes the result, which a
    /// showing springboard takes once nothing moves.
    private func clearRecentlyAddedMarksOfLaunchedApplications() {
        let markedApplications = layout.applications.filter(\.isRecentlyAdded)
        guard !markedApplications.isEmpty else { return }
        Task.detached(priority: .utility) {
            let launchedBundleIdentifiers = RecentlyAddedApplications.launchedBundleIdentifiers(
                among: markedApplications,
                hasBeenLaunched: RecentlyAddedApplications.hasBeenLaunched(applicationAt:)
            )
            guard !launchedBundleIdentifiers.isEmpty else { return }
            await LaunchpadServices.library.clearRecentlyAdded(forBundleIdentifiers: launchedBundleIdentifiers)
        }
    }

    /// Opens the application and closes the springboard, with 15's icon animation playing over the exit.
    private func launch(_ application: LaunchpadApplication, iconFrame: CGRect, iconImage: Any?) {
        if application.isRecentlyAdded {
            Task {
                await LaunchpadServices.library.clearRecentlyAdded(forBundleIdentifiers: [application.bundleIdentifier])
            }
        }
        if let bundleURL = application.bundleURL {
            ApplicationLauncher.launchApplication(at: bundleURL)
        } else {
            ApplicationLauncher.launchApplication(withBundleIdentifier: application.bundleIdentifier)
        }
        if let window, let interface, iconImage != nil, !iconFrame.isEmpty, !SpringboardPreferences.reducesMotion {
            // On the window's root layer, so the springboard fading out does not take it along. The model
            // holds the starting state: a frame drawn before the animation applies must not show the copy
            // already doubled — that flashed a faint square around the icon.
            let launchingIconLayer = CALayer()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            launchingIconLayer.frame = interface.containerLayer.convert(iconFrame, to: window.rootLayer)
            launchingIconLayer.contents = iconImage
            launchingIconLayer.contentsGravity = .resizeAspect
            launchingIconLayer.opacity = 0.9
            window.rootLayer.addSublayer(launchingIconLayer)
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
            launchAnimation.fillMode = .forwards
            launchAnimation.isRemovedOnCompletion = false
            CATransaction.begin()
            CATransaction.setCompletionBlock {
                MainActor.assumeIsolated {
                    launchingIconLayer.removeFromSuperlayer()
                }
            }
            launchingIconLayer.add(launchAnimation, forKey: "launch")
            CATransaction.commit()
        }
        hide(reason: "launching \(application.title)")
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

    // MARK: - Pinch

    /// The thumb-and-three-fingers pinch, read from the DockSwipe events the Dock still receives. macOS 27
    /// recognises this pinch in Spotlight, so the springboard only takes it over once Spotlight's own is
    /// turned off; otherwise both would open.
    private func handlePinch(_ dockSwipe: SpringboardInputEvent.DockSwipe) {
        guard dockSwipe.motion == SpringboardInputEvent.DockSwipe.pinchMotion else { return }
        #if DEBUG
        #log(.info, "Pinch event: phase \(dockSwipe.phase, privacy: .public), progress \(dockSwipe.progress, privacy: .public), velocity \(dockSwipe.velocity, privacy: .public), direction flag \(dockSwipe.directionFlag, privacy: .public)")
        #endif
        guard SpringboardPreferences.isSpotlightPinchDisabled, !Self.isDisabledByKillSwitch else { return }

        let intendedProgress = SpringboardPinch.intendedProgress(rawProgress: dockSwipe.progress, directionFlag: dockSwipe.directionFlag)
        if dockSwipe.hasEnded {
            endPinch(isCancelled: dockSwipe.isCancelled, intendedProgress: intendedProgress, velocity: dockSwipe.velocity)
            return
        }
        if dockSwipe.hasBegun, pinch == nil {
            beginPinch(isPinchingIn: SpringboardPinch.isPinchingIn(rawProgress: dockSwipe.progress, directionFlag: dockSwipe.directionFlag))
        }
        guard var currentPinch = pinch, let interface else { return }
        currentPinch.visibility = SpringboardPinch.visibility(forIntendedProgress: intendedProgress, isOpening: currentPinch.isOpening)
        pinch = currentPinch
        interface.setVisibility(currentPinch.visibility)
    }

    /// Pinching in opens a hidden springboard; spreading closes a shown one. Anything else is ignored,
    /// as is a new gesture while the last one is still settling.
    private func beginPinch(isPinchingIn: Bool) {
        guard springTimer == nil else { return }
        if isPinchingIn, !isVisible {
            show(reason: "pinch", animated: false)
            guard isVisible else { return }
            pinch = (isOpening: true, visibility: 0)
        } else if !isPinchingIn, isVisible, interface?.dragSession == nil {
            pinch = (isOpening: false, visibility: 1)
        }
    }

    /// Lets go: a completed pinch springs the rest of the way; an abandoned opening leaves with the
    /// normal exit animation, an abandoned closing snaps back (`-[LPSpringboard fluidGestureEnd:]`, `0x1000B12A4`).
    private func endPinch(isCancelled: Bool, intendedProgress: Double, velocity: Double) {
        guard let currentPinch = pinch else { return }
        pinch = nil
        let completes = SpringboardPinch.completes(isCancelled: isCancelled, intendedProgress: intendedProgress, isOpening: currentPinch.isOpening)
        switch (currentPinch.isOpening, completes) {
        case (true, true):
            runVisibilitySpring(from: currentPinch.visibility, velocity: velocity, target: 1) {}
        case (true, false):
            hide(reason: "pinch abandoned")
        case (false, true):
            window?.releaseKeyFocus()
            runVisibilitySpring(from: currentPinch.visibility, velocity: velocity, target: 0) { [weak self] in
                self?.hide(reason: "spread", animated: false)
            }
        case (false, false):
            interface?.setVisibility(1)
        }
    }

    /// Steps the spring 60 times a second until it settles, then runs `completion`.
    private func runVisibilitySpring(from visibility: Double, velocity: Double, target: Double, completion: @escaping @MainActor () -> Void) {
        stopSpring()
        visibilitySpring = SpringboardVisibilitySpring(visibility: visibility, velocity: velocity, target: target)
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now(), repeating: .nanoseconds(16_666_666))
        timer.setEventHandler {
            MainActor.assumeIsolated {
                let controller = SpringboardController.shared
                guard var spring = controller.visibilitySpring, let interface = controller.interface else {
                    controller.stopSpring()
                    return
                }
                spring.step()
                controller.visibilitySpring = spring
                interface.setVisibility(spring.visibility)
                CATransaction.flush()
                if spring.isFinished {
                    controller.stopSpring()
                    completion()
                }
            }
        }
        springTimer = timer
        timer.resume()
    }

    private func stopSpring() {
        springTimer?.cancel()
        springTimer = nil
        visibilitySpring = nil
    }

    private func stopPinch() {
        pinch = nil
        stopSpring()
    }
}
