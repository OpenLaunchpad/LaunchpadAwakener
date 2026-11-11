import CoreGraphics
import LaunchpadAwakenerSpringboardCore
import Testing

/// The springboard opens on the display the Dock is on, as macOS 15's Launchpad did
/// (`-[Springboard display]`, 15.5 `0x100008248`), and on the main display when that is unknown or gone.
@Suite("Display the springboard opens on")
struct SpringboardDisplayTests {
    @Test("it opens on the display the Dock is on")
    func dockDisplay() {
        #expect(SpringboardDisplay.displayToShowOn(dockDisplay: 3, activeDisplays: [1, 3], mainDisplay: 1) == 3)
    }

    @Test("it opens on the main display where the host cannot tell where the Dock is")
    func unknownDockDisplay() {
        #expect(SpringboardDisplay.displayToShowOn(dockDisplay: nil, activeDisplays: [1, 3], mainDisplay: 1) == 1)
    }

    @Test("it opens on the main display when the Dock's display has gone")
    func departedDockDisplay() {
        #expect(SpringboardDisplay.displayToShowOn(dockDisplay: 3, activeDisplays: [1], mainDisplay: 1) == 1)
    }

    /// Quartz calls before a change with only the begin flag, and after it with what changed — nothing at
    /// all for a display that stayed as it was. The springboard goes on any of the calls after.
    @Test("a reconfiguration callback before a change is not the change; every one after it is")
    func reconfigurationCallbacks() {
        #expect(!SpringboardDisplay.reportsFinishedReconfiguration(.beginConfigurationFlag))
        #expect(SpringboardDisplay.reportsFinishedReconfiguration(.addFlag))
        #expect(SpringboardDisplay.reportsFinishedReconfiguration(.removeFlag))
        #expect(SpringboardDisplay.reportsFinishedReconfiguration([.setModeFlag, .desktopShapeChangedFlag]))
        #expect(SpringboardDisplay.reportsFinishedReconfiguration([]))
    }

    /// Read from the machine the tests run on, which has at least its main display.
    @Test(
        "every active display has a size and a scale, the main display among them",
        .enabled(if: CGMainDisplayID() != kCGNullDirectDisplay)
    )
    func activeDisplays() throws {
        let activeDisplays = SpringboardDisplay.activeDisplays
        try #require(!activeDisplays.isEmpty)
        #expect(activeDisplays.contains(CGMainDisplayID()))
        for activeDisplay in activeDisplays {
            #expect(!CGDisplayBounds(activeDisplay).isEmpty)
            #expect(SpringboardDisplay.backingScaleFactor(of: activeDisplay) >= 1)
        }
    }
}
