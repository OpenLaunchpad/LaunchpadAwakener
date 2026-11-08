import AppKit
import LaunchpadAwakenerSpringboardCore

/// What the standalone app reads from the system in place of asking the Dock: the Dock's preferences,
/// the room 15 left for the Dock, and where the layout library lives.
enum StandaloneEnvironment {
    /// The Dock's own preferences domain, which holds `tilesize`, `orientation` and macOS 15's
    /// `springboard-*` keys. Thread-safe, so shared.
    nonisolated(unsafe) static let dockPreferences: UserDefaults = UserDefaults(suiteName: "com.apple.dock") ?? .standard

    /// The Dock's icon size when the preference is missing.
    static let defaultDockIconSize: Float = 64

    /// Where the Dock is and the room 15 left it, worked out from the Dock's preferences: 15 always left
    /// the Dock its room, hidden or not (`LPSpringboard.showsDock` is always YES), so the grid matches
    /// 15's even though the window covers the Dock here.
    @MainActor
    static var dockGeometry: SpringboardDockGeometry {
        let orientation = dockPreferences.string(forKey: "orientation").flatMap(DockOrientation.init(rawValue:)) ?? .bottom
        let storedIconSize = dockPreferences.object(forKey: "tilesize") as? NSNumber
        let iconSize = storedIconSize.map(\.floatValue).flatMap { $0 > 0 ? $0 : nil } ?? defaultDockIconSize
        return SpringboardDockGeometry(
            orientation: orientation,
            thickness: SpringboardMetrics.dockThickness(desiredTileSize: iconSize),
            notchHeight: mainScreen?.safeAreaInsets.top ?? 0
        )
    }

    /// The screen of the main display, where the springboard shows.
    @MainActor
    static var mainScreen: NSScreen? {
        screen(forDisplay: CGMainDisplayID())
    }

    @MainActor
    static func screen(forDisplay displayIdentifier: CGDirectDisplayID) -> NSScreen? {
        NSScreen.screens.first { screen in
            (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == displayIdentifier
        }
    }

    // MARK: - The layout library

    /// `~/Library/Application Support/LaunchpadAwakener/Standalone/Launchpad.db`. On its first start it
    /// imports the injected springboard's library when there is one — the same tables as macOS 15's, so
    /// the same importer reads it — and macOS 15's own layout otherwise. Both are only read.
    static var libraryConfiguration: LaunchpadLibrary.Configuration {
        var configuration = LaunchpadLibrary.Configuration.standard(itemsPerPage: SpringboardPreferences.itemsPerPage)
        let injectedLibraryURL = configuration.databaseURL
        configuration.databaseURL = injectedLibraryURL
            .deletingLastPathComponent()
            .appendingPathComponent("Standalone", isDirectory: true)
            .appendingPathComponent(injectedLibraryURL.lastPathComponent, isDirectory: false)
        if FileManager.default.fileExists(atPath: injectedLibraryURL.path) {
            configuration.legacyDatabaseURL = injectedLibraryURL
        }
        return configuration
    }
}
