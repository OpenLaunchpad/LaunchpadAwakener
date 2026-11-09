@testable import LaunchpadAwakenerPayloadCore
import LaunchpadAwakenerSpringboardCore
import Testing

/// How the springboard drives the Dock's `DockVisibility`: the show override macOS 15 set while it showed,
/// and the forced hiding it asked for while a folder was open.
///
/// `-[DockVisibility removeForceDockHiddenWithReason:]` raises when the Dock does not hold the reason
/// (27.2 `0x1000353BC`, 15.5 `0x100054FC4`), which crashes the Dock, so every hold has to be let go exactly
/// once, on the object that took it.
@Suite("The Dock's visibility")
@MainActor
struct DockBarVisibilityTests {
    /// Stands in for the Dock's `DockVisibility`, keeping its reasons the way the Dock does.
    private final class RecordingDockVisibility: DockVisibilityCalls {
        var calls: [String] = []
        var heldReasons: [String: Int] = [:]
        var showOverrideFlags: UInt64 = 0

        func setOverrideShowType(_ showType: UInt64) {
            calls.append("setOverrideShowType \(showType)")
            showOverrideFlags |= showType
        }

        func removeOverrideShowType(_ showType: UInt64) {
            calls.append("removeOverrideShowType \(showType)")
            showOverrideFlags &= ~showType
        }

        func forceDockHidden(reason: String) {
            calls.append("forceDockHidden")
            heldReasons[reason, default: 0] += 1
        }

        func removeForceDockHidden(reason: String) {
            calls.append("removeForceDockHidden")
            guard let count = heldReasons[reason] else {
                Issue.record("The Dock would raise: it does not hold \(reason)")
                return
            }
            heldReasons[reason] = count > 1 ? count - 1 : nil
        }

        func holdsForceHiddenReason(_ reason: String) -> Bool {
            heldReasons[reason] != nil
        }
    }

    private static func makeVisibility(controller: RecordingDockVisibility?) -> DockBarVisibility {
        DockBarVisibility { controller }
    }

    @Test("opening and closing a folder hides the Dock and lets it go, inside the springboard's override")
    func folderOpenedAndClosed() {
        let controller = RecordingDockVisibility()
        let visibility = Self.makeVisibility(controller: controller)

        visibility.apply(.keptVisible)
        visibility.apply(.hidden)
        visibility.apply(.keptVisible)
        visibility.apply(.unchanged)

        #expect(controller.calls == [
            "setOverrideShowType 1",
            "forceDockHidden",
            "removeForceDockHidden",
            "removeOverrideShowType 1",
        ])
        #expect(controller.heldReasons.isEmpty)
        #expect(controller.showOverrideFlags == 0)
    }

    @Test("a springboard shown over an open folder takes both holds, and gives them back as it goes")
    func shownOverAnOpenFolder() {
        let controller = RecordingDockVisibility()
        let visibility = Self.makeVisibility(controller: controller)

        visibility.apply(.hidden)
        #expect(controller.calls == ["setOverrideShowType 1", "forceDockHidden"])

        // Going without an animation drops both at once: the folder's hold first.
        visibility.apply(.unchanged)
        #expect(controller.calls.suffix(2) == ["removeForceDockHidden", "removeOverrideShowType 1"])
        #expect(controller.heldReasons.isEmpty)
    }

    @Test("asking for the same thing again asks the Dock nothing")
    func repeatedRequestsAreIgnored() {
        let controller = RecordingDockVisibility()
        let visibility = Self.makeVisibility(controller: controller)

        visibility.apply(.hidden)
        visibility.apply(.hidden)
        visibility.apply(.unchanged)
        visibility.apply(.unchanged)

        #expect(controller.calls == [
            "setOverrideShowType 1",
            "forceDockHidden",
            "removeForceDockHidden",
            "removeOverrideShowType 1",
        ])
    }

    @Test("a hold the Dock no longer has is not let go, which would raise")
    func droppedHoldIsNotLetGo() {
        let controller = RecordingDockVisibility()
        let visibility = Self.makeVisibility(controller: controller)
        visibility.apply(.hidden)

        // Something in the Dock cleared the reasons behind the springboard's back.
        controller.heldReasons.removeAll()
        visibility.apply(.keptVisible)

        #expect(!controller.calls.contains("removeForceDockHidden"))

        // The next folder takes a fresh hold.
        visibility.apply(.hidden)
        #expect(controller.calls.last == "forceDockHidden")
        #expect(controller.heldReasons.count == 1)
    }

    @Test("without the Dock's visibility controller nothing is asked, and nothing is let go later")
    func missingControllerAsksNothing() {
        let visibility = Self.makeVisibility(controller: nil)

        visibility.apply(.hidden)
        visibility.apply(.unchanged)

        #expect(!visibility.isHoldingDockHidden)
        #expect(!visibility.isHoldingDockShown)
    }
}
