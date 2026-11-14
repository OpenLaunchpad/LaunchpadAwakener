import Foundation
@testable import LaunchpadAwakenerAppCore
import LaunchpadAwakenerPayloadInterface
import Testing

/// Stands in for the bundle the app assembles; nothing here reads it, only passes its path along.
private let exampleBundleURL = URL(
    fileURLWithPath: "/Users/example/Library/Application Support/LaunchpadAwakener/LaunchpadDockIcon.app"
)

/// The switch for the Launchpad icon on the Dock's Apps tile.
///
/// The app decides and the payload is told, so what a payload is handed — the state *and* the bundle the
/// icon is rendered from — is the observable behaviour here. These tests watch that, not the preference
/// domain it came out of.
@Suite("The Launchpad icon switch")
@MainActor
struct DockAppsIconControllerTests {
    /// What the payloads were handed, in order. Replies are whatever the test needs them to be.
    private final class PayloadRecorder {
        private(set) var settingsSent: [(isEnabled: Bool, iconBundlePath: String)] = []
        var replies: [DockAppsIconReply] = []

        func send(isEnabled: Bool, iconBundlePath: String) -> [DockAppsIconReply] {
            settingsSent.append((isEnabled: isEnabled, iconBundlePath: iconBundlePath))
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
        prepareIconBundle: @escaping @Sendable () throws -> URL = { exampleBundleURL },
        userDefaults: UserDefaults,
        recorder: PayloadRecorder
    ) -> DockAppsIconController {
        DockAppsIconController(
            prepareIconBundle: prepareIconBundle,
            userDefaults: userDefaults,
            sendToPayloads: { isEnabled, iconBundlePath in
                recorder.send(isEnabled: isEnabled, iconBundlePath: iconBundlePath)
            }
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

    @Test("switching tells the payload the new state and which bundle the icon comes from")
    func sendsTheStateAndTheBundle() async {
        await withPreferences { userDefaults in
            let recorder = PayloadRecorder()
            let bundleURL = URL(fileURLWithPath: "/tmp/Example/LaunchpadDockIcon.app")
            let controller = makeController(
                prepareIconBundle: { bundleURL },
                userDefaults: userDefaults,
                recorder: recorder
            )

            await controller.setEnabled(false)
            await controller.setEnabled(true)

            #expect(recorder.settingsSent.map(\.isEnabled) == [false, true])
            #expect(
                recorder.settingsSent.allSatisfy { $0.iconBundlePath == bundleURL.path },
                "the bundle goes with every message, so switching on needs no second one"
            )
        }
    }

    @Test("the icon's bundle is assembled once, however often the switch moves")
    func assemblesTheBundleOnce() async {
        await withPreferences { userDefaults in
            let preparationCount = Counter()
            let controller = makeController(
                prepareIconBundle: {
                    preparationCount.increment()
                    return exampleBundleURL
                },
                userDefaults: userDefaults,
                recorder: PayloadRecorder()
            )

            await controller.applyStoredSetting()
            await controller.setEnabled(false)
            await controller.setEnabled(true)

            #expect(preparationCount.value == 1)
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

    @Test("a build whose resources lost the icon cannot be switched on, and says why")
    func refusesWithoutAnIcon() async throws {
        try await withPreferences { userDefaults in
            let recorder = PayloadRecorder()
            let controller = makeController(
                prepareIconBundle: { throw DockAppsIconHost.Failure.missingResources },
                userDefaults: userDefaults,
                recorder: recorder
            )

            await controller.setEnabled(false)

            #expect(recorder.settingsSent.isEmpty, "there is no icon to send")
            #expect(!controller.isAvailable)
            let errorDescription = try #require(controller.lastErrorDescription)
            #expect(errorDescription.contains("Launchpad icon"))
        }
    }

    /// Counts calls from a `@Sendable` closure without the test having to reason about isolation.
    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        var value: Int {
            lock.withLock { count }
        }

        func increment() {
            lock.withLock { count += 1 }
        }
    }
}
