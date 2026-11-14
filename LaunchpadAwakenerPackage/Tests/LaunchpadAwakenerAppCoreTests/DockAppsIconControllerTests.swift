import Foundation
@testable import LaunchpadAwakenerAppCore
import LaunchpadAwakenerPayloadInterface
import Testing

/// The switch for the Launchpad icon on the Dock's Apps tile.
///
/// The app decides and the payload is told, so what a payload is handed — the state *and* the path — is
/// the observable behaviour here. These tests watch that, not the preference domain it came out of.
@Suite("The Launchpad icon switch")
@MainActor
struct DockAppsIconControllerTests {
    /// What the payloads were handed, in order. Replies are whatever the test needs them to be.
    private final class PayloadRecorder {
        private(set) var settingsSent: [(isEnabled: Bool, iconPath: String)] = []
        var replies: [DockAppsIconReply] = []

        func send(isEnabled: Bool, iconPath: String) -> [DockAppsIconReply] {
            settingsSent.append((isEnabled: isEnabled, iconPath: iconPath))
            return replies
        }
    }

    /// A preference domain of this test's own, removed afterwards: `.standard` would carry the developer's
    /// own switch into the test, and the tests into their Mac.
    private func withPreferences<Result>(_ body: (UserDefaults) async throws -> Result) async rethrows -> Result {
        let suiteName = "com.MxIris.LaunchpadAwakener.Tests.\(UUID().uuidString)"
        let userDefaults = UserDefaults(suiteName: suiteName)!
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        return try await body(userDefaults)
    }

    private func makeController(
        iconPath: String? = "/Applications/LaunchpadAwakener.app/Contents/Resources/LaunchpadDockIcon.icns",
        userDefaults: UserDefaults,
        recorder: PayloadRecorder
    ) -> DockAppsIconController {
        DockAppsIconController(
            iconPath: iconPath,
            userDefaults: userDefaults,
            sendToPayloads: { isEnabled, iconPath in recorder.send(isEnabled: isEnabled, iconPath: iconPath) }
        )
    }

    @Test("a Mac that has never been asked gets the Launchpad icon")
    func isOnByDefault() async {
        await withPreferences { userDefaults in
            let controller = makeController(userDefaults: userDefaults, recorder: PayloadRecorder())

            #expect(controller.isEnabled)
        }
    }

    @Test("the choice survives a relaunch")
    func remembersTheChoice() async throws {
        try await withPreferences { userDefaults in
            let recorder = PayloadRecorder()
            await makeController(userDefaults: userDefaults, recorder: recorder).setEnabled(false)

            let afterRelaunch = makeController(userDefaults: userDefaults, recorder: recorder)

            #expect(!afterRelaunch.isEnabled)
        }
    }

    @Test("switching tells the payload the new state and where the icon is")
    func sendsTheStateAndThePath() async {
        await withPreferences { userDefaults in
            let recorder = PayloadRecorder()
            let controller = makeController(
                iconPath: "/Applications/Example.app/Contents/Resources/LaunchpadDockIcon.icns",
                userDefaults: userDefaults,
                recorder: recorder
            )

            await controller.setEnabled(false)
            await controller.setEnabled(true)

            #expect(recorder.settingsSent.map(\.isEnabled) == [false, true])
            #expect(
                recorder.settingsSent.allSatisfy { $0.iconPath == "/Applications/Example.app/Contents/Resources/LaunchpadDockIcon.icns" },
                "the path goes with every message, so switching on needs no second one"
            )
        }
    }

    @Test("setting the switch to what it already is does not disturb the Dock")
    func sendsNothingWhenNothingChanged() async {
        await withPreferences { userDefaults in
            let recorder = PayloadRecorder()
            let controller = makeController(userDefaults: userDefaults, recorder: recorder)

            await controller.setEnabled(true)

            #expect(recorder.settingsSent.isEmpty)
        }
    }

    @Test("the stored choice reaches payloads that were already there when the app started")
    func appliesTheStoredChoiceAtLaunch() async {
        await withPreferences { userDefaults in
            userDefaults.set(false, forKey: "DockAppsIconEnabled")
            let recorder = PayloadRecorder()
            let controller = makeController(userDefaults: userDefaults, recorder: recorder)

            await controller.applyStoredSetting()

            #expect(recorder.settingsSent.map(\.isEnabled) == [false])
        }
    }

    @Test("a Dock the payload cannot change says so")
    func reportsAPayloadThatCannotChangeTheTile() async throws {
        try await withPreferences { userDefaults in
            let recorder = PayloadRecorder()
            recorder.replies = [.unsupported(reason: "This Dock's icon setter does not match")]
            let controller = makeController(userDefaults: userDefaults, recorder: recorder)

            await controller.setEnabled(false)

            let errorDescription = try #require(controller.lastErrorDescription)
            #expect(errorDescription.contains("icon setter"))
        }
    }

    @Test("a Dock that took the change leaves nothing to report")
    func clearsTheErrorOnceAPayloadTakesIt() async {
        await withPreferences { userDefaults in
            let recorder = PayloadRecorder()
            recorder.replies = [.unsupported(reason: "This Dock's icon setter does not match")]
            let controller = makeController(userDefaults: userDefaults, recorder: recorder)
            await controller.setEnabled(false)

            recorder.replies = [.applied(appsTileCount: 1)]
            await controller.setEnabled(true)

            #expect(controller.lastErrorDescription == nil)
        }
    }

    @Test("a build whose bundle lost the icon cannot be switched on, and says why")
    func refusesWithoutAnIcon() async throws {
        try await withPreferences { userDefaults in
            let recorder = PayloadRecorder()
            let controller = makeController(iconPath: nil, userDefaults: userDefaults, recorder: recorder)

            #expect(!controller.isAvailable)
            await controller.setEnabled(false)

            #expect(recorder.settingsSent.isEmpty, "there is no icon to send")
            let errorDescription = try #require(controller.lastErrorDescription)
            #expect(errorDescription.contains("Launchpad icon"))
        }
    }
}
