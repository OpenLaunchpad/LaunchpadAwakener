import CoreGraphics
import Foundation
import ObjCRuntimeToolbox
import OSToolbox
import LaunchpadAwakenerSpringboardCore

// MARK: - The Dock's classes

/// What dragging onto the Dock reads from and calls on the Dock's `DockBar`. The signatures are the same in
/// 26.6.2 and 27.2.
@RuntimeClassProxy("DockBar")
protocol DockBarDropReception {
    /// Global coordinates with a top-left origin: where a pointer counts as on the bar, which is what
    /// macOS 15's Launchpad compared a drag with.
    var inBarRect: CGRect? { get }
    /// A `DockAnimationThread`.
    var animationThread: NSObject? { get }
    /// The `DOCKTrashTile`.
    var trashTile: NSObject? { get }
    /// The tile standing in for the gap a drag opens.
    var dummyTile: NSObject? { get }
    /// Whether the Dock believes its gap is open. It can be wrong; see ``LiveDockDragEvents/isGapOpen()``.
    var dummyTileInDock: Bool? { get }
    /// The Dock writes it under its own lock, which the payload cannot take; written without the lock, the
    /// frame running at that moment finishes as it started, and the next one reads it.
    func setFDragging(_ isDragging: Bool)
    /// The tile across `location`, found under the Dock's own lock — the gap's stand-in included. Without
    /// exact bounds only the position along the bar counts.
    func findTileAtLocation(_ location: CGPoint, checkExactBounds: Bool, shouldLock: Bool) -> NSObject?
    /// Runs `body` at once with the Dock's `DockEventQueue`, under the queue's lock. Nothing that takes the
    /// Dock's own lock may be called in it: the animation thread takes the two the other way round.
    func accessingLockedEventQueue(_ body: @escaping @convention(block) (NSObject?) -> Void)
    /// Has the Dock write its tiles to `com.apple.dock` four seconds later; main thread only.
    func makeDirty()
}

/// The Dock's animation thread, which runs the frames that move the gap.
@RuntimeClassProxy("DockAnimationThread")
protocol DockAnimationThreadWaking {
    /// Signals the thread's condition; safe from any thread.
    func wakeup()
    /// Keeps the frames at 60 a second: half a second after the last mouse event the Dock drops to 30, and
    /// while the springboard shows, the pointer's events are the springboard's.
    func updateLastMouseEventTimestampToNow()
}

/// The Dock's event queue, which its animation thread empties at the start of every frame. Only reached in
/// ``DockBarDropReception/accessingLockedEventQueue(_:)``.
@RuntimeClassProxy("DockEventQueue")
protocol DockEventQueueDragging {
    /// Starts the Dock's drag handling: from the next frame on, the gap follows the real pointer.
    func addDragEnterWithFlags(_ flags: UInt64)
    /// Whether a DragLeave was queued; false when it took back a DragEnter not handled yet instead.
    func addDragLeave() -> Bool?
    func setEventMousePosition(_ position: CGPoint)
    /// The gap takes `tiles`; an application already in the Dock moves there instead of appearing twice.
    func addDragDropAtMousePoint(_ mousePoint: CGPoint, tiles: NSArray)
}

/// The Dock's drag controller, reached through a global of its own.
///
/// Only what is being dragged is set here. Its `startDragWithProcess:` takes a pointer to a struct, which
/// the proxies cannot declare, and on 27.2 it also arms the screen edges for switching spaces; nothing on the
/// way to the gap or the drop reads what it sets. Its `endDragForcingTrashRedraw:` resets state all over the
/// Dock — the window drag controller's, Exposé's — whether a drag was started or not, so the drag here never
/// calls it either.
@RuntimeClassProxy("DragController")
protocol DockDragControllerContents {
    /// What is being dragged, as flags; see ``DockDropTarget/applicationFileContents``. Zero when nothing
    /// is: a real drag works its contents out only from zero.
    func setCurrentDragContents(_ contents: UInt64)
}

/// Makes the Dock's tiles.
@RuntimeClassProxy("DOCKFileTileFactory")
protocol DockFileTileMaking {
    /// A `DOCKFileTile` for an application; `dock` is the `DockBar`. Without a bookmark the tile makes its own,
    /// which is what finds the application when it is in the Dock already.
    static func tileForDock(_ dock: NSObject, url: NSURL, bookmark: NSData?) -> NSObject?
}

/// Any tile in the Dock.
@RuntimeClassProxy("Tile")
protocol DockTileGeometry {
    /// The tile's rectangle, reaching across the bar to the edge of the screen; global coordinates with a
    /// top-left origin. Kept up to date by the animation thread, so a read on the main thread is at most
    /// half a frame old.
    var axFrame: CGRect? { get }
}

// MARK: - The drop target

/// The Dock as a place to drop an application dragged out of the springboard, as macOS 15's Launchpad
/// handed one to the Dock.
///
/// 15 made a CoreDrag of the application's file URL and fed it to the Dock's drag tracking
/// (`-[DockBar injectIntoCoreDragTrackingProcWithMessage:window:refCon:theDrag:]`). That method's signature
/// spells out HIServices' whole `OpaqueCoreDrag` layout, which differs between 26.6.2 and 27.2, and on 27.2
/// its in-place message pins the Dock's pointer at (-1, -1). Underneath, the gap and the drop are events in
/// the Dock's own queue, handled on its animation thread a frame at a time; the payload queues them itself,
/// the same way on both systems: a DragEnter has the Dock open a gap under the real pointer every frame, a
/// DragDrop of a new tile lands in the gap, and a DragLeave closes it. The reverse engineering is in
/// `/Volumes/RE/Dock/27.2/Notes/DragToDock.md` and `/Volumes/RE/Dock/26.6.2/Notes/DragToDock.md`.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockDropTarget")
@MainActor
final class DockDropTarget: SpringboardDockDropTarget {
    static let shared = DockDropTarget()

    /// What the Dock's drag controller calls a drag of an application's file URL: 2, a file URL, and 4, an
    /// application. It is what the Dock works out for 15's drag of an application.
    nonisolated static let applicationFileContents: UInt64 = 6

    /// Every method dragging onto the Dock calls.
    nonisolated static let requiredMethods: [DockMethodSignature] =
        DockMethodSignature.signatures(
            ofClassNamed: DockBarDropReceptionImplementation.runtimeClassName,
            requirements: DockBarDropReceptionImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockAnimationThreadWakingImplementation.runtimeClassName,
            requirements: DockAnimationThreadWakingImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockEventQueueDraggingImplementation.runtimeClassName,
            requirements: DockEventQueueDraggingImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockDragControllerContentsImplementation.runtimeClassName,
            requirements: DockDragControllerContentsImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockFileTileMakingImplementation.runtimeClassName,
            requirements: DockFileTileMakingImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockTileGeometryImplementation.runtimeClassName,
            requirements: DockTileGeometryImplementation.methodRequirements
        )

    /// The methods the running Dock lacks or has with another signature: empty when everything matches.
    /// Logged once as the payload starts; a mismatch switches only dragging onto the Dock off.
    nonisolated static func missingMethods() -> [String] {
        requiredMethods.compactMap { signature in
            signature.isPresent ? nil : signature.methodName
        }
    }

    /// Whether every method matches, worked out once.
    nonisolated static let isCompatible: Bool = missingMethods().isEmpty

    func contains(_ globalPoint: CGPoint) -> Bool {
        guard let dockBar = DockBarReference.dockBar.flatMap({ DockBarDropReceptionImplementation($0) }) else { return false }
        return dockBar.inBarRect?.contains(globalPoint) ?? false
    }

    func makeDragWindow() -> (any SpringboardDragWindow)? {
        DockDragWindow(displayIdentifier: CGMainDisplayID())
    }

    func beginDrag(ofApplicationAt bundleURL: URL, at globalPoint: CGPoint) -> (any SpringboardDockDrag)? {
        guard let calls = LiveDockDragEvents.current else { return nil }
        #log(.info, "Handing \(bundleURL.lastPathComponent, privacy: .public) to the Dock")
        return DockApplicationDrag(bundleURL: bundleURL, calls: calls)
    }

    #if DEBUG
    /// Logs what dragging onto the Dock would reach — the drag controller, the bar, the Trash — reading only,
    /// so that a development build can be checked from the log without dragging anything. Asked a few seconds
    /// after the payload arrives: the Dock may not have made its singletons before.
    static func logReachability() {
        guard isCompatible else { return }
        let dockBar = DockBarReference.dockBar.flatMap { DockBarDropReceptionImplementation($0) }
        let barRect = dockBar?.inBarRect
        let trashFrame = dockBar?.trashTile.flatMap { DockTileGeometryImplementation($0)?.axFrame }
        let reachesDragController = DockBarReference.dragController.flatMap { DockDragControllerContentsImplementation($0) } != nil
        #log(.info, "Self-check: dragging onto the Dock reaches the drag controller: \(reachesDragController, privacy: .public); the bar at \(barRect.map { "\($0)" } ?? "nowhere", privacy: .public); the Trash at \(trashFrame.map { "\($0)" } ?? "nowhere", privacy: .public)")
    }
    #endif
}

// MARK: - One drag

/// The calls an application held over the Dock makes on the Dock, behind a protocol so that their order and
/// pairing can be tested without the Dock.
@MainActor
protocol DockDragEventCalls: AnyObject {
    /// Marks what is dragged as an application's file URL and queues a DragEnter, which starts the Dock's
    /// drag handling: from the next frame on, the gap follows the real pointer.
    func queueApplicationDragEnter()
    /// Wakes the animation thread, which sleeps once no event of its own comes in.
    func wakeAnimationThread()
    func isOnTrash(_ globalPoint: CGPoint) -> Bool
    /// Stops the gap following the pointer, as the Dock stops it before it takes a drop of its own.
    func stopGapFollowingPointer()
    /// Whether the gap is really in the Dock.
    func isGapOpen() -> Bool
    /// Queues a DragDrop of a new tile for the application, which the gap takes; false when no tile could
    /// be made.
    func queueDrop(ofApplicationAt bundleURL: URL, at globalPoint: CGPoint) -> Bool
    /// Has the Dock save its tiles, four seconds later.
    func scheduleSave()
    /// Queues a DragLeave, which closes the gap wherever the pointer is and stops the Dock's drag handling;
    /// it takes back a DragEnter not handled yet instead.
    func queueDragLeave()
    /// The drag controller forgets what was dragged, so that the next drag from the Finder works its
    /// contents out afresh rather than counting as an application.
    func clearDragContents()
}

/// An application held over the Dock, the Dock keeping a gap open for it under the pointer.
///
/// Every way out — leaving the bar, letting go, Escape, the springboard going — ends the drag exactly once:
/// a DragLeave, then the contents cleared. Without the DragLeave the Dock keeps an empty slot for good;
/// left at an application's, the contents make the next document dragged in from the Finder count as an
/// application. The Dock has no timeout for either.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockApplicationDrag")
@MainActor
final class DockApplicationDrag: SpringboardDockDrag {
    private let bundleURL: URL
    private let calls: any DockDragEventCalls
    /// Set once the drag has ended; nothing reaches the Dock after that.
    private(set) var isOver = false

    init(bundleURL: URL, calls: any DockDragEventCalls) {
        self.bundleURL = bundleURL
        self.calls = calls
        calls.queueApplicationDragEnter()
        calls.wakeAnimationThread()
    }

    func move(to globalPoint: CGPoint) {
        guard !isOver else { return }
        calls.wakeAnimationThread()
    }

    /// The Trash is checked first: a drop the Dock took there would move the application to the Trash. A drop
    /// is queued only where the gap really is, and before the DragLeave, so that one frame handles both in
    /// that order.
    func drop(at globalPoint: CGPoint) -> SpringboardDockDropResult {
        guard !isOver else { return .none }
        defer { end() }
        if calls.isOnTrash(globalPoint) {
            #log(.info, "Let \(self.bundleURL.lastPathComponent, privacy: .public) go on the Trash")
            return .trash
        }
        calls.stopGapFollowingPointer()
        guard calls.isGapOpen() else {
            #log(.info, "Let \(self.bundleURL.lastPathComponent, privacy: .public) go on the Dock where it had no gap")
            return .none
        }
        guard calls.queueDrop(ofApplicationAt: bundleURL, at: globalPoint) else {
            #log(.error, "The Dock made no tile for \(self.bundleURL.path, privacy: .public)")
            return .none
        }
        calls.scheduleSave()
        calls.wakeAnimationThread()
        #log(.info, "The Dock keeps \(self.bundleURL.lastPathComponent, privacy: .public)")
        return .kept
    }

    func cancel() {
        end()
    }

    /// The contents are cleared at once rather than once the DragLeave is handled. A frame running at
    /// that moment then closes the gap a frame early, which the DragLeave would do anyway; and a drop is
    /// queued only after the gap stopped following the pointer and a locked look-up waited out the frame
    /// in progress, so no frame that could still move the gap reads the cleared contents.
    private func end() {
        guard !isOver else { return }
        isOver = true
        calls.queueDragLeave()
        calls.wakeAnimationThread()
        calls.clearDragContents()
    }
}

// MARK: - The live Dock

/// ``DockDragEventCalls`` on the running Dock, through the proxies above.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "LiveDockDragEvents")
@MainActor
final class LiveDockDragEvents: DockDragEventCalls {
    private let dockBar: DockBarDropReceptionImplementation
    private let dragController: DockDragControllerContentsImplementation

    private init(dockBar: DockBarDropReceptionImplementation, dragController: DockDragControllerContentsImplementation) {
        self.dockBar = dockBar
        self.dragController = dragController
    }

    /// The Dock's bar and drag controller as they are now; nil when either is out of reach or does not match.
    static var current: LiveDockDragEvents? {
        guard DockDropTarget.isCompatible else { return nil }
        guard
            let dockBar = DockBarReference.dockBar.flatMap({ DockBarDropReceptionImplementation($0) }),
            let dragController = DockBarReference.dragController.flatMap({ DockDragControllerContentsImplementation($0) })
        else {
            #log(.error, "The Dock's bar or drag controller is out of reach; nothing is handed to the Dock")
            return nil
        }
        return LiveDockDragEvents(dockBar: dockBar, dragController: dragController)
    }

    func queueApplicationDragEnter() {
        dragController.setCurrentDragContents(DockDropTarget.applicationFileContents)
        dockBar.accessingLockedEventQueue { eventQueueObject in
            guard let eventQueueObject, let eventQueue = DockEventQueueDraggingImplementation(eventQueueObject) else { return }
            eventQueue.addDragEnterWithFlags(DockDropTarget.applicationFileContents)
        }
    }

    func wakeAnimationThread() {
        guard let animationThread = dockBar.animationThread.flatMap({ DockAnimationThreadWakingImplementation($0) }) else { return }
        animationThread.updateLastMouseEventTimestampToNow()
        animationThread.wakeup()
    }

    func isOnTrash(_ globalPoint: CGPoint) -> Bool {
        guard let trashFrame = dockBar.trashTile.flatMap({ DockTileGeometryImplementation($0)?.axFrame }) else { return false }
        return trashFrame.contains(globalPoint)
    }

    func stopGapFollowingPointer() {
        dockBar.setFDragging(false)
    }

    /// The Dock's own flag says a gap is open even when it never opened one — when the pointer came
    /// straight onto the middle of an icon — and a drop then goes to the end of the applications instead. So
    /// the gap's stand-in must be among the Dock's tiles: looked up where the stand-in itself is, under the
    /// Dock's own lock, the only way in to the tiles that takes it. Not where the pointer is: the gap trails
    /// the pointer and is still widening as it opens, so the pointer is often over a neighbour, and above
    /// the icons the gap stays put while the pointer moves on.
    ///
    /// The look-up also waits out a frame in progress, which may move the stand-in after its frame was read;
    /// once the gap no longer follows the pointer nothing moves it again, so a second look settles it.
    func isGapOpen() -> Bool {
        guard dockBar.dummyTileInDock == true, let dummyTile = dockBar.dummyTile else { return false }
        for _ in 0..<2 {
            guard let dummyFrame = DockTileGeometryImplementation(dummyTile)?.axFrame, !dummyFrame.isEmpty else { return false }
            let dummyCenter = CGPoint(x: dummyFrame.midX, y: dummyFrame.midY)
            if dockBar.findTileAtLocation(dummyCenter, checkExactBounds: false, shouldLock: true) === dummyTile {
                return true
            }
        }
        return false
    }

    func queueDrop(ofApplicationAt bundleURL: URL, at globalPoint: CGPoint) -> Bool {
        // Made outside the queue's lock: making a tile takes the Dock's own.
        guard
            let dockBarObject = dockBar.host as? NSObject,
            let tile = DockFileTileMakingImplementation.tileForDock(dockBarObject, url: bundleURL as NSURL, bookmark: nil)
        else { return false }
        dockBar.accessingLockedEventQueue { eventQueueObject in
            guard let eventQueueObject, let eventQueue = DockEventQueueDraggingImplementation(eventQueueObject) else { return }
            eventQueue.setEventMousePosition(globalPoint)
            eventQueue.addDragDropAtMousePoint(globalPoint, tiles: [tile] as NSArray)
        }
        return true
    }

    func scheduleSave() {
        dockBar.makeDirty()
    }

    func queueDragLeave() {
        dockBar.accessingLockedEventQueue { eventQueueObject in
            guard let eventQueueObject, let eventQueue = DockEventQueueDraggingImplementation(eventQueueObject) else { return }
            _ = eventQueue.addDragLeave()
        }
    }

    func clearDragContents() {
        dragController.setCurrentDragContents(0)
    }
}
