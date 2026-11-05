import CoreGraphics
import CoreServices
import CoreText
import Foundation
import ImageIO
import OSLog
import QuartzCore

/// What the overlay needs from one Dock event, read on the event's own thread.
///
/// `CGEvent` is not `Sendable`, so the hook extracts these fields before crossing to the main actor.
struct OverlayInputEvent: Sendable {
    enum Kind: Sendable {
        case keyDown(keyCode: Int64, characters: String, hasCommandModifier: Bool)
        case keyUpOrModifierChange
        case leftMouseDown
        case leftMouseUp
        case otherMouseButton
        /// Mouse movement, scrolling, gestures, system-defined keys: always left to the Dock.
        case unhandled
    }

    let kind: Kind
    let location: CGPoint

    init(event: CGEvent, eventType: UInt32) {
        location = event.location
        switch CGEventType(rawValue: eventType) {
        case .keyDown?:
            var characterCount = 0
            var characterBuffer = [UniChar](repeating: 0, count: 8)
            event.keyboardGetUnicodeString(
                maxStringLength: characterBuffer.count,
                actualStringLength: &characterCount,
                unicodeString: &characterBuffer
            )
            kind = .keyDown(
                keyCode: event.getIntegerValueField(.keyboardEventKeycode),
                characters: String(utf16CodeUnits: characterBuffer, count: characterCount),
                hasCommandModifier: event.flags.contains(.maskCommand)
            )
        case .keyUp?, .flagsChanged?:
            kind = .keyUpOrModifierChange
        case .leftMouseDown?:
            kind = .leftMouseDown
        case .leftMouseUp?:
            kind = .leftMouseUp
        case .leftMouseDragged?, .rightMouseDown?, .rightMouseUp?, .rightMouseDragged?:
            kind = .otherMouseButton
        default:
            kind = .unhandled
        }
    }
}

/// The prototype's stand-in for macOS 15's Launchpad: one full-screen Dock window.
///
/// Shows the first page of the old layout, or every application matching what has been typed.
/// Like macOS 15, it takes key focus onto the Dock's connection while shown, sits above the menu bar
/// with the Dock bar raised above it (levels 27 and 29), closes on Escape or a click outside the
/// icons, and launches an application on a click or Return.
///
/// A full-screen window that keeps input and never lets go is what made the earlier macOS 26 attempt
/// unrecoverable, so whatever breaks, it closes itself after `idleDismissInterval` without input, and
/// the kill-switch file closes it on the next event.
@MainActor
final class LaunchpadPrototypeOverlay {
    static let shared = LaunchpadPrototypeOverlay()

    /// Creating this file (for example over ssh) makes the hook fall back to the system's Apps.
    nonisolated static let killSwitchPath = "/tmp/LaunchpadAwakener.disabled"

    nonisolated static var isDisabledByKillSwitch: Bool {
        FileManager.default.fileExists(atPath: killSwitchPath)
    }

    private struct ItemHitArea {
        let frame: CGRect
        let pageItem: LaunchpadDatabase.PageItem
    }

    private struct RaisedDockWindow {
        let identifier: UInt32
        let bounds: CGRect
    }

    private static let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakener", category: "LaunchpadPrototype")
    private static let idleDismissInterval: TimeInterval = 20
    private static let launchpadWindowLevel: Int32 = 27
    private static let dockWindowLevel: Int32 = 20
    private static let raisedDockWindowLevel: Int32 = 29
    /// The tags macOS 15's `-[Springboard init]` passed for its window.
    private static let launchpadWindowTags: UInt64 = 1024
    private static let columnCount = 7
    private static let rowCount = 5
    private static let escapeKeyCode: Int64 = 53
    private static let deleteKeyCode: Int64 = 51
    private static let returnKeyCode: Int64 = 36

    private var containerWindow: NSObject?
    private var rootLayer: CALayer?
    private var pageLayer: CALayer?
    private var connectionIdentifier: UInt32 = 0
    private var displayBounds: CGRect = .zero
    private var displayScaleFactor: CGFloat = 2
    private var hasKeyFocus = false
    private var raisedDockWindows: [RaisedDockWindow] = []
    private var firstPageItems: [LaunchpadDatabase.PageItem] = []
    private var allApplications: [LaunchpadDatabase.PageItem] = []
    private var searchText = ""
    private var itemHitAreas: [ItemHitArea] = []
    /// Bumped on every input and every hide, so a stale idle timer cannot hide a later showing.
    private var idleGeneration = 0

    var isVisible: Bool { containerWindow != nil }

    func toggle() {
        if isVisible {
            hide(reason: "toggled")
        } else {
            show()
        }
    }

    // MARK: - Showing and hiding

    private func show() {
        guard let mainConnectionIdentifier = SkyLightBridge.mainConnectionIdentifier else { return }
        let displayIdentifier = CGMainDisplayID()
        let mainDisplayBounds = CGDisplayBounds(displayIdentifier)

        guard
            let window = DockHostInterface.makeLayerKitWindow(
                frame: mainDisplayBounds,
                connectionIdentifier: mainConnectionIdentifier,
                displayIdentifier: displayIdentifier,
                tags: Self.launchpadWindowTags,
                level: Self.dockWindowLevel
            ),
            let windowRootLayer = DockHostInterface.rootLayer(of: window)
        else { return }
        let windowIdentifier = DockHostInterface.windowIdentifier(of: window)

        containerWindow = window
        rootLayer = windowRootLayer
        connectionIdentifier = mainConnectionIdentifier
        displayBounds = mainDisplayBounds
        displayScaleFactor = Self.displayScale(of: displayIdentifier)
        firstPageItems = LaunchpadDatabase.firstPageItems()
        allApplications = LaunchpadDatabase.allApplications()
        searchText = ""
        renderPage()

        let launchpadLevelResult = SkyLightBridge.setWindowLevel(
            Self.launchpadWindowLevel,
            ofWindowWithIdentifier: windowIdentifier,
            onConnection: mainConnectionIdentifier
        )
        raiseDockWindows()
        DockHostInterface.order(window, order: 1)
        let keyFocusResult = SkyLightBridge.stealKeyFocus(onConnection: mainConnectionIdentifier)
        hasKeyFocus = keyFocusResult == 0

        Self.logger.info(
            "Raised Dock windows \(self.raisedDockWindows.map { "\($0.identifier) \(NSStringFromRect($0.bounds))" }, privacy: .public); Dock bar rect \(DockBarReference.currentBarRect.map { NSStringFromRect($0) } ?? "unknown", privacy: .public)"
        )
        Self.logger.info(
            "Shown: window \(windowIdentifier, privacy: .public), level result \(launchpadLevelResult ?? -1, privacy: .public), key focus result \(keyFocusResult ?? -1, privacy: .public), \(self.firstPageItems.count, privacy: .public) first-page item(s), \(self.allApplications.count, privacy: .public) application(s)"
        )
        restartIdleTimer()
    }

    func hide(reason: String) {
        guard let window = containerWindow else { return }
        idleGeneration += 1
        DockHostInterface.order(window, order: 0)
        if hasKeyFocus {
            SkyLightBridge.releaseKeyFocus(onConnection: connectionIdentifier)
            hasKeyFocus = false
        }
        for raisedDockWindow in raisedDockWindows {
            SkyLightBridge.setWindowLevel(
                Self.dockWindowLevel,
                ofWindowWithIdentifier: raisedDockWindow.identifier,
                onConnection: connectionIdentifier
            )
        }
        raisedDockWindows = []
        itemHitAreas = []
        pageLayer = nil
        rootLayer = nil
        containerWindow = nil
        Self.logger.info("Hidden: \(reason, privacy: .public)")
    }

    private func restartIdleTimer() {
        idleGeneration += 1
        let scheduledGeneration = idleGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleDismissInterval) {
            MainActor.assumeIsolated {
                let overlay = LaunchpadPrototypeOverlay.shared
                guard overlay.idleGeneration == scheduledGeneration else { return }
                overlay.hide(reason: "idle")
            }
        }
    }

    /// Raises the Dock's own on-screen windows at the Dock level above the overlay, the way macOS 15
    /// kept the Dock bar visible and usable on top of Launchpad.
    private func raiseDockWindows() {
        let processIdentifier = ProcessInfo.processInfo.processIdentifier
        guard let windowDescriptions = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] else {
            Self.logger.error("Could not list windows")
            return
        }
        raisedDockWindows = windowDescriptions.compactMap { windowDescription -> RaisedDockWindow? in
            guard
                (windowDescription[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                (windowDescription[kCGWindowLayer as String] as? NSNumber)?.int32Value == Self.dockWindowLevel,
                let windowNumber = windowDescription[kCGWindowNumber as String] as? NSNumber,
                let boundsDictionary = windowDescription[kCGWindowBounds as String] as? NSDictionary,
                let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary)
            else { return nil }
            return RaisedDockWindow(identifier: windowNumber.uint32Value, bounds: bounds)
        }
        for raisedDockWindow in raisedDockWindows {
            SkyLightBridge.setWindowLevel(
                Self.raisedDockWindowLevel,
                ofWindowWithIdentifier: raisedDockWindow.identifier,
                onConnection: connectionIdentifier
            )
        }
    }

    // MARK: - Input

    /// Called for every event the Dock receives. Returns whether the overlay consumed it; anything
    /// not consumed goes on to the Dock as usual.
    func handle(_ inputEvent: OverlayInputEvent) -> Bool {
        guard isVisible else { return false }
        if Self.isDisabledByKillSwitch {
            hide(reason: "kill switch")
            return false
        }

        switch inputEvent.kind {
        case let .keyDown(keyCode, characters, hasCommandModifier):
            restartIdleTimer()
            handleKeyDown(keyCode: keyCode, characters: characters, hasCommandModifier: hasCommandModifier)
            return true
        case .keyUpOrModifierChange:
            return true
        case .leftMouseDown:
            // Clicks on the Dock bar stay the Dock's, as they did over macOS 15's Launchpad.
            guard !isInsideDockBar(inputEvent.location) else { return false }
            restartIdleTimer()
            handleClick(at: inputEvent.location)
            return true
        case .leftMouseUp:
            guard isInsideDockBar(inputEvent.location) else { return true }
            // Whatever the click on the Dock opens takes key focus, so close afterwards, as
            // macOS 15's Launchpad closed when something was opened from the Dock.
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    LaunchpadPrototypeOverlay.shared.hide(reason: "clicked the Dock")
                }
            }
            return false
        case .otherMouseButton:
            return !isInsideDockBar(inputEvent.location)
        case .unhandled:
            return false
        }
    }

    private func handleKeyDown(keyCode: Int64, characters: String, hasCommandModifier: Bool) {
        switch keyCode {
        case Self.escapeKeyCode:
            if searchText.isEmpty {
                hide(reason: "escape")
            } else {
                searchText = ""
                renderPage()
            }
        case Self.deleteKeyCode:
            guard !searchText.isEmpty else { return }
            searchText.removeLast()
            renderPage()
        case Self.returnKeyCode:
            if let firstApplication = visibleItems.first(where: { $0.kind == .application }) {
                launch(firstApplication)
            }
        default:
            guard
                !hasCommandModifier,
                !characters.isEmpty,
                !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return }
            searchText += characters
            renderPage()
        }
        Self.logger.info("Key \(keyCode, privacy: .public); search text is now \"\(self.searchText, privacy: .public)\"")
    }

    private func handleClick(at location: CGPoint) {
        let pointInWindow = CGPoint(x: location.x - displayBounds.minX, y: location.y - displayBounds.minY)
        guard let hitArea = itemHitAreas.first(where: { $0.frame.contains(pointInWindow) }) else {
            hide(reason: "clicked outside the icons")
            return
        }
        switch hitArea.pageItem.kind {
        case .application:
            launch(hitArea.pageItem)
        case .folder:
            Self.logger.info("Folder \(hitArea.pageItem.title, privacy: .public) clicked; folders are not in the prototype yet")
        }
    }

    private func isInsideDockBar(_ location: CGPoint) -> Bool {
        DockBarReference.currentBarRect?.contains(location) ?? false
    }

    private func launch(_ pageItem: LaunchpadDatabase.PageItem) {
        guard
            let bundleIdentifier = pageItem.bundleIdentifier,
            let applicationURLs = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?
                .takeRetainedValue() as? [URL],
            let applicationURL = applicationURLs.first
        else {
            Self.logger.error("No application found for \(pageItem.title, privacy: .public) (\(pageItem.bundleIdentifier ?? "no bundle identifier", privacy: .public))")
            return
        }
        // Give focus back before the application activates, so it becomes key as usual.
        hide(reason: "launching \(pageItem.title)")
        let launchStatus = LSOpenCFURLRef(applicationURL as CFURL, nil)
        Self.logger.info("Launched \(applicationURL.path, privacy: .public): status \(launchStatus, privacy: .public)")
    }

    // MARK: - Drawing

    /// The first page, or the applications matching the search text.
    private var visibleItems: [LaunchpadDatabase.PageItem] {
        let maximumItemCount = Self.columnCount * Self.rowCount
        guard !searchText.isEmpty else { return Array(firstPageItems.prefix(maximumItemCount)) }
        return Array(
            allApplications
                .filter { $0.title.localizedCaseInsensitiveContains(searchText) }
                .prefix(maximumItemCount)
        )
    }

    private func renderPage() {
        guard let rootLayer else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        pageLayer?.removeFromSuperlayer()
        let newPageLayer = makePageLayer(size: displayBounds.size)
        // Lay the page out top-down whatever the window's root layer does.
        newPageLayer.isGeometryFlipped = !rootLayer.contentsAreFlipped()
        rootLayer.addSublayer(newPageLayer)
        pageLayer = newPageLayer
        CATransaction.commit()
        CATransaction.flush()
    }

    private func makePageLayer(size: CGSize) -> CALayer {
        let newPageLayer = CALayer()
        newPageLayer.frame = CGRect(origin: .zero, size: size)
        newPageLayer.backgroundColor = CGColor(gray: 0, alpha: 0.6)

        let searchFieldLayer = makeTextLayer(
            text: searchText.isEmpty ? "Type to search" : searchText,
            fontSize: 15,
            opacity: searchText.isEmpty ? 0.5 : 1
        )
        searchFieldLayer.frame = CGRect(x: size.width / 2 - 120, y: size.height * 0.06, width: 240, height: 22)
        newPageLayer.addSublayer(searchFieldLayer)

        let horizontalMargin = size.width * 0.12
        let topMargin = size.height * 0.14
        let cellWidth = (size.width - horizontalMargin * 2) / CGFloat(Self.columnCount)
        let cellHeight = size.height * 0.72 / CGFloat(Self.rowCount)
        let iconSide = min(cellWidth, cellHeight) * 0.62

        var newItemHitAreas: [ItemHitArea] = []
        for (itemIndex, pageItem) in visibleItems.enumerated() {
            let cellOrigin = CGPoint(
                x: horizontalMargin + CGFloat(itemIndex % Self.columnCount) * cellWidth,
                y: topMargin + CGFloat(itemIndex / Self.columnCount) * cellHeight
            )
            let iconFrame = CGRect(x: cellOrigin.x + (cellWidth - iconSide) / 2, y: cellOrigin.y, width: iconSide, height: iconSide)
            let titleFrame = CGRect(x: cellOrigin.x, y: iconFrame.maxY + 8, width: cellWidth, height: 18)

            let iconLayer = CALayer()
            iconLayer.frame = iconFrame
            iconLayer.contentsGravity = .resizeAspect
            iconLayer.contentsScale = displayScaleFactor
            if let iconImage = pageItem.iconPNGData.flatMap(Self.makeImage(fromPNGData:)) {
                iconLayer.contents = iconImage
            } else {
                iconLayer.backgroundColor = CGColor(gray: 1, alpha: pageItem.kind == .folder ? 0.25 : 0.12)
                iconLayer.cornerRadius = iconSide * 0.22
            }
            newPageLayer.addSublayer(iconLayer)

            let titleLayer = makeTextLayer(text: pageItem.title, fontSize: 13, opacity: 1)
            titleLayer.frame = titleFrame
            newPageLayer.addSublayer(titleLayer)

            newItemHitAreas.append(ItemHitArea(frame: iconFrame.union(titleFrame), pageItem: pageItem))
        }
        itemHitAreas = newItemHitAreas
        return newPageLayer
    }

    private func makeTextLayer(text: String, fontSize: CGFloat, opacity: Float) -> CATextLayer {
        let textLayer = CATextLayer()
        textLayer.string = text
        textLayer.font = CTFontCreateUIFontForLanguage(.label, fontSize, nil)
        textLayer.fontSize = fontSize
        textLayer.foregroundColor = CGColor(gray: 1, alpha: 1)
        textLayer.opacity = opacity
        textLayer.alignmentMode = .center
        textLayer.truncationMode = .end
        textLayer.contentsScale = displayScaleFactor
        return textLayer
    }

    private static func displayScale(of displayIdentifier: CGDirectDisplayID) -> CGFloat {
        guard let displayMode = CGDisplayCopyDisplayMode(displayIdentifier), displayMode.width > 0 else { return 2 }
        return CGFloat(displayMode.pixelWidth) / CGFloat(displayMode.width)
    }

    private static func makeImage(fromPNGData pngData: Data) -> CGImage? {
        guard let imageSource = CGImageSourceCreateWithData(pngData as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    }
}
