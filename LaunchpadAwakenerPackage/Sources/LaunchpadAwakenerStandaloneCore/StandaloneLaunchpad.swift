import AppKit
import LaunchpadAwakenerSpringboardCore
import OSToolbox
import ServiceManagement

/// The standalone Launchpad: chooses its host, opens the layout library, and shows and hides the
/// springboard for the app delegate.
///
/// The app stays running once the springboard hides, so the next showing has the library and the icons
/// at hand, as the Dock's always did.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "StandaloneLaunchpad")
@MainActor
public final class StandaloneLaunchpad {
    public static let shared = StandaloneLaunchpad()

    private var hasStarted = false

    private init() {}

    public var isVisible: Bool {
        SpringboardController.shared.isVisible
    }

    /// Chooses the standalone host, opens the library and starts the watchdog. Call once, at launch.
    public func start() {
        guard !hasStarted else { return }
        hasStarted = true
        SpringboardHostSystem.bootstrap(host: StandaloneSpringboardHost.shared)
        StandaloneWatchdog.shared.start()
        LaunchpadServices.start()
        #log(.info, "Started; the library is \(StandaloneEnvironment.libraryConfiguration.databaseURL.path, privacy: .public)")
    }

    /// Shows the springboard over everything, unless the kill switch is down.
    public func show(reason: String) {
        guard !SpringboardController.isDisabledByKillSwitch else {
            #log(.error, "Not shown (\(reason, privacy: .public)): \(SpringboardController.killSwitchPath, privacy: .public) exists")
            return
        }
        SpringboardController.shared.show(reason: reason)
    }

    public func hide(reason: String) {
        SpringboardController.shared.hide(reason: reason)
    }

    public func toggle(reason: String) {
        if isVisible {
            hide(reason: reason)
        } else {
            show(reason: reason)
        }
    }

    // MARK: - Opening at login

    private static let hasRegisteredLoginItemKey = "StandaloneHasRegisteredLoginItem"

    /// Opens at login unless the user turned that off: registered once, on the first launch.
    public func registerLoginItemOnFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.hasRegisteredLoginItemKey) else { return }
        UserDefaults.standard.set(true, forKey: Self.hasRegisteredLoginItemKey)
        StandaloneLoginItem.setOpensAtLogin(true)
    }

    // MARK: - Self-check

    /// Launched with `--self-check`, a development build builds the springboard off screen once the
    /// library loads — the shared self-check does that — logs what the standalone host found, and quits.
    /// Nothing goes on screen, so it can run on a test machine without anyone looking.
    public static var isSelfCheckLaunch: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--self-check")
        #else
        false
        #endif
    }

    /// How long a self-check launch stays: long enough for the library to load and the icons to render.
    private static let selfCheckDuration: TimeInterval = 15

    public func runSelfCheck() {
        let displayIdentifier = CGMainDisplayID()
        let host = StandaloneSpringboardHost.shared
        let dockGeometry = host.dockGeometry
        #log(.info, "Self-check (standalone): Dock \(dockGeometry.orientation.rawValue, privacy: .public) \(dockGeometry.thickness, privacy: .public), notch \(dockGeometry.notchHeight, privacy: .public)")
        if let wallpaper = StandaloneWallpaper.image(onDisplay: displayIdentifier) {
            #log(.info, "Self-check (standalone): wallpaper from \(wallpaper.source.rawValue, privacy: .public), \(wallpaper.image.width, privacy: .public)×\(wallpaper.image.height, privacy: .public) pixels; screen recording allowed \(CGPreflightScreenCaptureAccess(), privacy: .public)")
        } else {
            #log(.error, "Self-check (standalone): no wallpaper picture; the background falls back to 15's gradient")
        }
        if let iconStyle = host.iconStyle {
            #log(.info, "Self-check (standalone): icon style \(iconStyle.style, privacy: .public), compositing filter \(iconStyle.glassCompositingFilterName ?? "none", privacy: .public)")
        } else {
            #log(.error, "Self-check (standalone): no icon style; icons use the default style")
        }
        let libraryConfiguration = host.libraryConfiguration
        #log(.info, "Self-check (standalone): library \(libraryConfiguration.databaseURL.path, privacy: .public), first import from \(libraryConfiguration.legacyDatabaseURL?.path ?? "nothing", privacy: .public)")
        if let window = StandaloneSpringboardWindow(displayIdentifier: displayIdentifier) {
            #log(.info, "Self-check (standalone): window \(window.selfCheckDescription, privacy: .public), not ordered in")
        } else {
            #log(.error, "Self-check (standalone): no window could be made for display \(displayIdentifier, privacy: .public)")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.selfCheckDuration) {
            MainActor.assumeIsolated {
                #log(.info, "Self-check (standalone): done, quitting")
                NSApp.terminate(nil)
            }
        }
    }
}

/// The standalone app's delegate: shows the springboard when the app is opened or its Dock icon is
/// clicked, and hides it when another application becomes active.
@MainActor
public final class StandaloneApplicationDelegate: NSObject, NSApplicationDelegate {
    override public init() {
        super.init()
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        let launchpad = StandaloneLaunchpad.shared
        launchpad.start()
        if StandaloneLaunchpad.isSelfCheckLaunch {
            launchpad.runSelfCheck()
            return
        }
        launchpad.registerLoginItemOnFirstLaunch()
        // Opened at login, it waits in the background for the first click on its Dock icon.
        guard !Self.wasLaunchedAsLoginItem else { return }
        launchpad.show(reason: "launched")
    }

    /// A click on the app's Dock icon, or opening it again from the Finder.
    public func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !StandaloneLaunchpad.isSelfCheckLaunch else { return false }
        StandaloneLaunchpad.shared.show(reason: "reopened")
        return false
    }

    /// Command-Tab or a click elsewhere: 15's Launchpad went away when another application came forward.
    public func applicationDidResignActive(_ notification: Notification) {
        StandaloneLaunchpad.shared.hide(reason: "another application became active")
    }

    /// Whether this launch is the one at login: the open event says so for an item under Open at Login.
    private static var wasLaunchedAsLoginItem: Bool {
        guard let openEvent = NSAppleEventManager.shared().currentAppleEvent else { return false }
        return openEvent.eventID == kAEOpenApplication
            && openEvent.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
