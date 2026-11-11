import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerPayloadCore
import LaunchpadAwakenerSpringboardCore
import Testing

/// What an application held over the Dock asks of the Dock, in what order. The Dock has no timeout for a
/// drag left open: without the DragLeave it keeps an empty slot for good, and with the contents left at an
/// application's, the next document dragged in from the Finder counts as an application
/// (`/Volumes/RE/Dock/27.2/Notes/DragToDock.md`, `/Volumes/RE/Dock/26.6.2/Notes/DragToDock.md`).
@Suite("An application held over the Dock")
@MainActor
struct DockApplicationDragTests {
    final class RecordingDockDragEvents: DockDragEventCalls {
        enum Call: Equatable {
            case queueApplicationDragEnter
            case wakeAnimationThread
            case stopGapFollowingPointer
            case queueDrop(URL, CGPoint)
            case scheduleSave
            case queueDragLeave
            case clearDragContents
        }

        var calls: [Call] = []
        var isOnTrashAnswer = false
        var isGapOpenAnswer = true
        var canMakeTile = true

        func queueApplicationDragEnter() {
            calls.append(.queueApplicationDragEnter)
        }

        func wakeAnimationThread() {
            calls.append(.wakeAnimationThread)
        }

        func isOnTrash(_ globalPoint: CGPoint) -> Bool {
            isOnTrashAnswer
        }

        func stopGapFollowingPointer() {
            calls.append(.stopGapFollowingPointer)
        }

        func isGapOpen() -> Bool {
            isGapOpenAnswer
        }

        func queueDrop(ofApplicationAt bundleURL: URL, at globalPoint: CGPoint) -> Bool {
            guard canMakeTile else { return false }
            calls.append(.queueDrop(bundleURL, globalPoint))
            return true
        }

        func scheduleSave() {
            calls.append(.scheduleSave)
        }

        func queueDragLeave() {
            calls.append(.queueDragLeave)
        }

        func clearDragContents() {
            calls.append(.clearDragContents)
        }
    }

    private static let bundleURL = URL(filePath: "/Applications/Calculator.app", directoryHint: .isDirectory)
    private static let releasePoint = CGPoint(x: 735, y: 916)
    /// How every drag ends: the DragLeave, the frame that handles it, then the contents.
    private static let ending: [RecordingDockDragEvents.Call] = [.queueDragLeave, .wakeAnimationThread, .clearDragContents]

    private static func beginDrag(_ events: RecordingDockDragEvents) -> DockApplicationDrag {
        let drag = DockApplicationDrag(bundleURL: bundleURL, calls: events)
        events.calls.removeAll()
        return drag
    }

    @Test("coming onto the Dock marks an application's drag and has the Dock open a gap")
    func beginning() {
        let events = RecordingDockDragEvents()

        _ = DockApplicationDrag(bundleURL: Self.bundleURL, calls: events)

        #expect(events.calls == [.queueApplicationDragEnter, .wakeAnimationThread])
    }

    @Test("moving only wakes the Dock, whose frames move the gap under the real pointer")
    func moving() {
        let events = RecordingDockDragEvents()
        let drag = Self.beginDrag(events)

        drag.move(to: CGPoint(x: 700, y: 900))
        drag.move(to: CGPoint(x: 710, y: 900))

        #expect(events.calls == [.wakeAnimationThread, .wakeAnimationThread])
    }

    @Test("let go on the gap, the drop is queued after the gap stopped and before the DragLeave, and saved")
    func dropOnGap() {
        let events = RecordingDockDragEvents()
        let drag = Self.beginDrag(events)

        let result = drag.drop(at: Self.releasePoint)

        #expect(result == .kept)
        #expect(events.calls == [
            .stopGapFollowingPointer,
            .queueDrop(Self.bundleURL, Self.releasePoint),
            .scheduleSave,
            .wakeAnimationThread,
        ] + Self.ending)
        #expect(drag.isOver)
    }

    @Test("let go on the Trash, the Dock gets no drop — it would move the application to the Trash")
    func dropOnTrash() {
        let events = RecordingDockDragEvents()
        events.isOnTrashAnswer = true
        let drag = Self.beginDrag(events)

        let result = drag.drop(at: Self.releasePoint)

        #expect(result == .trash)
        #expect(events.calls == Self.ending)
    }

    @Test("let go where the Dock opened no gap, it gets no drop, which would land at the end of its applications")
    func dropWithoutGap() {
        let events = RecordingDockDragEvents()
        events.isGapOpenAnswer = false
        let drag = Self.beginDrag(events)

        let result = drag.drop(at: Self.releasePoint)

        #expect(result == .none)
        #expect(events.calls == [.stopGapFollowingPointer] + Self.ending)
    }

    @Test("when the Dock makes no tile, nothing is kept and the drag still ends")
    func dropWithoutTile() {
        let events = RecordingDockDragEvents()
        events.canMakeTile = false
        let drag = Self.beginDrag(events)

        let result = drag.drop(at: Self.releasePoint)

        #expect(result == .none)
        #expect(events.calls == [.stopGapFollowingPointer] + Self.ending)
    }

    @Test("a cancel ends the drag once, and nothing reaches the Dock after it")
    func cancelEndsOnce() {
        let events = RecordingDockDragEvents()
        let drag = Self.beginDrag(events)

        drag.cancel()
        drag.cancel()
        drag.move(to: Self.releasePoint)
        let result = drag.drop(at: Self.releasePoint)

        #expect(result == .none)
        #expect(events.calls == Self.ending)
    }

    @Test("after a drop, a cancel — Escape, the springboard going — asks nothing more of the Dock")
    func cancelAfterDrop() {
        let events = RecordingDockDragEvents()
        let drag = Self.beginDrag(events)
        _ = drag.drop(at: Self.releasePoint)
        events.calls.removeAll()

        drag.cancel()

        #expect(events.calls.isEmpty)
    }
}
