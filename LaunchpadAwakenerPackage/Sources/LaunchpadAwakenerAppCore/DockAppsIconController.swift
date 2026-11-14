import Foundation
import LaunchpadAwakenerPayloadInterface
import OSToolbox

/// The switch for showing the Launchpad icon on the Dock's Apps tile.
///
/// Once the payload is in, every way of opening Apps opens this replica of Launchpad, so the tile in the
/// Dock is a picture of something the click no longer does. This is what turns that picture into the
/// Launchpad icon — and what turns it back.
///
/// The app owns the decision and the path: the payload runs inside the Dock and is told both, rather than
/// reading a preference domain of the app's or guessing where the app is installed. Sending happens
/// through ``PayloadInjectionCoordinator``, which also hands the settings to each payload as it connects,
/// so a Dock restart or an app relaunch needs nothing from here.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockAppsIconController")
@Observable
@MainActor
public final class DockAppsIconController {
    /// Name of the icon in the app's bundle: the standalone Launchpad's own icon, copied in by the
    /// "Embed Standalone Launchpad" build phase so that the Dock gets the Launchpad icon without the
    /// gear this app's own icon carries.
    public static let bundledIconResourceName = "LaunchpadDockIcon"

    /// Whether the Dock's Apps tile should show the Launchpad icon. Persisted; on by default.
    public private(set) var isEnabled: Bool

    /// Most recent failure or refusal, cleared by the next successful change. For display.
    public private(set) var lastErrorDescription: String?

    /// The icon this app hands the Dock; nil when the bundle has none, which no supported build should be.
    public let iconPath: String?

    /// Whether the switch can do anything at all. False only on a build whose bundle lost the icon.
    public var isAvailable: Bool { iconPath != nil }

    @ObservationIgnored
    private let userDefaults: UserDefaults

    @ObservationIgnored
    private let sendToPayloads: @MainActor (Bool, String) async -> [DockAppsIconReply]

    public convenience init(injectionCoordinator: PayloadInjectionCoordinator) {
        self.init(
            iconPath: Bundle.main.url(forResource: Self.bundledIconResourceName, withExtension: "icns")?.path,
            sendToPayloads: { [weak injectionCoordinator] isEnabled, iconPath in
                await injectionCoordinator?.applyDockAppsIcon(isEnabled: isEnabled, iconPath: iconPath) ?? []
            }
        )
    }

    public init(
        iconPath: String?,
        userDefaults: UserDefaults = .standard,
        sendToPayloads: @escaping @MainActor (Bool, String) async -> [DockAppsIconReply]
    ) {
        self.iconPath = iconPath
        self.userDefaults = userDefaults
        self.sendToPayloads = sendToPayloads
        isEnabled = userDefaults.object(forKey: PreferenceKey.isEnabled) as? Bool ?? true
        if iconPath == nil {
            #log(.error, "This build has no \(Self.bundledIconResourceName, privacy: .public).icns; the Apps tile keeps the Dock's own icon")
        }
    }

    /// Hands the stored setting to whatever payloads are reachable. Called once as the app starts.
    ///
    /// Also what records the setting for payloads that connect later, so calling it before anything is
    /// injected is not wasted.
    public func applyStoredSetting() async {
        await send(isEnabled: isEnabled)
    }

    /// Records the choice and hands it to the payloads.
    ///
    /// `isEnabled` changes before the first suspension point, so a switch bound to it moves at once and the
    /// Dock catches up; `await`ing the whole thing is what lets a test see what the payloads were told.
    public func setEnabled(_ shouldEnable: Bool) async {
        guard shouldEnable != isEnabled else { return }
        isEnabled = shouldEnable
        userDefaults.set(shouldEnable, forKey: PreferenceKey.isEnabled)
        #log(.info, "The Apps tile should now show \(shouldEnable ? "the Launchpad icon" : "the Dock's own icon", privacy: .public)")
        await send(isEnabled: shouldEnable)
    }

    private func send(isEnabled: Bool) async {
        guard let iconPath else {
            lastErrorDescription = "This build does not carry the Launchpad icon."
            return
        }
        let replies = await sendToPayloads(isEnabled, iconPath)
        // One Dock per login session, so in practice there is one reply; a refusal from any of them is
        // worth showing, and the rest are the state the user asked for.
        let refusal = replies.compactMap { reply -> String? in
            guard case .unsupported(let reason) = reply else { return nil }
            return reason
        }.first
        lastErrorDescription = refusal
    }

    private enum PreferenceKey {
        static let isEnabled = "DockAppsIconEnabled"
    }
}
