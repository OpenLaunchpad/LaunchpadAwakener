import CoreGraphics

/// Which display the springboard opens on, and what CoreGraphics says about a display.
///
/// macOS 15 opened Launchpad on the display the Dock was on, whatever opened it: `-[Springboard display]`
/// (15.5 `0x100008248`) is `[[DockBar display] identifier]`, and the Launchpad key, a hot corner, the Dock's
/// icon and the pinch only toggled it — none of them looked at the pointer. To have it on another display,
/// the user moves the Dock there first: with the pointer at that display's bottom edge, while displays
/// have separate Spaces.
package enum SpringboardDisplay {
    /// `dockDisplay` while it is active; the main display where the host cannot tell where the Dock is, or
    /// where the Dock's display has just gone.
    package static func displayToShowOn(
        dockDisplay: CGDirectDisplayID?,
        activeDisplays: [CGDirectDisplayID],
        mainDisplay: CGDirectDisplayID
    ) -> CGDirectDisplayID {
        guard let dockDisplay, activeDisplays.contains(dockDisplay) else { return mainDisplay }
        return dockDisplay
    }

    /// The display the springboard opens on now, from where the host says the Dock is.
    @MainActor
    package static var current: CGDirectDisplayID {
        displayToShowOn(
            dockDisplay: SpringboardHostSystem.host.dockDisplayIdentifier,
            activeDisplays: activeDisplays,
            mainDisplay: CGMainDisplayID()
        )
    }

    /// The displays that can be drawn on now; empty when CoreGraphics cannot say.
    package static var activeDisplays: [CGDirectDisplayID] {
        var displayCount: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &displayCount) == .success, displayCount > 0 else { return [] }
        var displayIdentifiers = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        guard CGGetActiveDisplayList(displayCount, &displayIdentifiers, &displayCount) == .success else { return [] }
        return Array(displayIdentifiers.prefix(Int(displayCount)))
    }

    /// Pixels per point in the display's current mode; 2 when the mode cannot be read.
    package static func backingScaleFactor(of displayIdentifier: CGDirectDisplayID) -> CGFloat {
        guard let displayMode = CGDisplayCopyDisplayMode(displayIdentifier), displayMode.width > 0 else { return 2 }
        return CGFloat(displayMode.pixelWidth) / CGFloat(displayMode.width)
    }
}
