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
///
/// What is sent is a *bundle*, not an image file: the payload renders the icon through IconServices so
/// that it follows the light, dark and tinted appearances, and IconServices renders from a bundle. The
/// app assembles that bundle on first use — see ``DockAppsIconHost``.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockAppsIconController")
@Observable
@MainActor
public final class DockAppsIconController {
    /// Whether the Dock's Apps tile should show the Launchpad icon. Persisted; on by default.
    public private(set) var isEnabled: Bool

    /// Most recent failure or refusal, cleared by the next successful change. For display.
    public private(set) var lastErrorDescription: String?

    /// Whether the switch can do anything at all. False on a build whose resources lost the icon, and
    /// after assembling the icon's bundle has failed.
    public private(set) var isAvailable: Bool

    /// The assembled bundle's path, once it has been assembled. Kept so the work happens once per run.
    @ObservationIgnored
    private var iconBundlePath: String?

    @ObservationIgnored
    private let userDefaults: UserDefaults

    @ObservationIgnored
    private let prepareIconBundle: @Sendable () throws -> URL

    @ObservationIgnored
    private let sendToPayloads: @MainActor (Bool, String) async -> [DockAppsIconReply]

    public convenience init(injectionCoordinator: PayloadInjectionCoordinator) {
        self.init(
            prepareIconBundle: { try DockAppsIconHost.prepare() },
            sendToPayloads: { [weak injectionCoordinator] isEnabled, iconBundlePath in
                await injectionCoordinator?.applyDockAppsIcon(
                    isEnabled: isEnabled,
                    iconBundlePath: iconBundlePath
                ) ?? []
            }
        )
    }

    public init(
        prepareIconBundle: @escaping @Sendable () throws -> URL,
        userDefaults: UserDefaults = .standard,
        sendToPayloads: @escaping @MainActor (Bool, String) async -> [DockAppsIconReply]
    ) {
        self.prepareIconBundle = prepareIconBundle
        self.userDefaults = userDefaults
        self.sendToPayloads = sendToPayloads
        isEnabled = userDefaults.object(forKey: PreferenceKey.isEnabled) as? Bool ?? true
        // Optimistic until something actually fails: whether the icon can be assembled is only known
        // once it has been tried, and trying costs file work that does not belong in an initialiser.
        isAvailable = true
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
        guard let iconBundlePath = await resolvedIconBundlePath() else { return }
        let replies = await sendToPayloads(isEnabled, iconBundlePath)
        // One Dock per login session, so in practice there is one reply; a refusal from any of them is
        // worth showing, and the rest are the state the user asked for.
        let refusal = replies.compactMap { reply -> String? in
            guard case .unsupported(let reason) = reply else { return nil }
            return reason
        }.first
        lastErrorDescription = refusal
    }

    /// The assembled bundle, assembling it the first time it is needed.
    ///
    /// Off the main actor: assembling copies the icon's resources, and the first run of a new build is
    /// the one time that is more than two `stat`s.
    private func resolvedIconBundlePath() async -> String? {
        if let iconBundlePath { return iconBundlePath }
        let prepareIconBundle = prepareIconBundle
        do {
            let hostBundleURL = try await Task.detached(priority: .userInitiated) {
                try prepareIconBundle()
            }.value
            iconBundlePath = hostBundleURL.path
            isAvailable = true
            return hostBundleURL.path
        } catch {
            let description = (error as? DockAppsIconHost.Failure)?.errorDescription
                ?? "The Launchpad icon could not be prepared: \(error.localizedDescription)"
            #log(.error, "\(description, privacy: .public) The Apps tile keeps the Dock's own icon.")
            lastErrorDescription = description
            isAvailable = false
            return nil
        }
    }

    private enum PreferenceKey {
        static let isEnabled = "DockAppsIconEnabled"
    }
}
