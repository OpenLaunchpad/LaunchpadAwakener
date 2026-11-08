import AppKit
import LaunchpadAwakenerSpringboardCore

/// The springboard's host in the standalone app: an ordinary window above everything, the replicas of
/// the Dock's layer classes, the wallpaper read from its file, and the icon style worked out from the
/// system's settings rather than read from the Dock.
///
/// There is no Dock to keep clear of, no glass, no uninstaller and no text input helper here.
final class StandaloneSpringboardHost: SpringboardHost {
    static let shared = StandaloneSpringboardHost()

    nonisolated init() {}

    nonisolated var layerFactory: any SpringboardLayerFactory {
        ReplicaSpringboardLayerFactory()
    }

    /// macOS 15's keys are the Dock's: the same `com.apple.dock` domain the injected springboard reads.
    nonisolated var preferences: UserDefaults {
        StandaloneEnvironment.dockPreferences
    }

    nonisolated var libraryConfiguration: LaunchpadLibrary.Configuration {
        StandaloneEnvironment.libraryConfiguration
    }

    var dockGeometry: SpringboardDockGeometry {
        StandaloneEnvironment.dockGeometry
    }

    var iconStyle: SpringboardIconStyle? {
        StandaloneIconStyle.current
    }

    var applicationUninstaller: (any SpringboardApplicationUninstaller)? {
        nil
    }

    func makeWindow(onDisplay displayIdentifier: CGDirectDisplayID) -> (any SpringboardWindow)? {
        StandaloneSpringboardWindow(displayIdentifier: displayIdentifier)
    }

    func wallpaperImage(onDisplay displayIdentifier: CGDirectDisplayID) -> CGImage? {
        StandaloneWallpaper.image(onDisplay: displayIdentifier)?.image
    }

    var offersGlassBackground: Bool {
        false
    }

    func makeGlassBackground(frame: CGRect, scale: CGFloat, backdropGroupName: String) -> (any SpringboardGlassBackground)? {
        nil
    }

    /// The fields are edited in place; the input methods reach them through the window's content view.
    func makeHostedTextField(configuration: SpringboardHostedTextFieldConfiguration) -> (any SpringboardHostedTextField)? {
        nil
    }

    var inputMethod: (any SpringboardInputMethod)? {
        StandaloneInputMethod.shared
    }

    /// The Dock is covered, so nothing on screen belongs to it.
    func isOnDock(_ globalPoint: CGPoint) -> Bool {
        false
    }
}
