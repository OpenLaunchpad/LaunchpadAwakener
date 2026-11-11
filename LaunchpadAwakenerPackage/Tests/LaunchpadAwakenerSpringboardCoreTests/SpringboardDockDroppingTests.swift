import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// Dragging an icon onto the Dock, by macOS 15.5's rules: on the Dock the icon dims to half and an
/// application is handed to the Dock (`-[Springboard didDragItem:withEvent:andLayer:]`, 15.5 `0x1000936BC`);
/// let go there, the Dock keeps it and the springboard puts the icon back in its place at once, without
/// sliding (`cancelDrag:0` from `-[ECSBDragCapture leftMouseUp:in:]`, `0x1000B65B0`); let go on the Trash,
/// it asks to delete an application that can be deleted (`-[ECSBSpringboard confirmRemoveItem:]`,
/// `0x1000F5FF0`).
@Suite("Dragging an icon onto the Dock")
@MainActor
struct SpringboardDockDroppingTests {
    // MARK: - Stand-ins for the Dock

    final class RecordingDragWindow: SpringboardDragWindow {
        let rootLayer = CALayer()
        private(set) var isOrderedIn = false

        func orderIn() {
            isOrderedIn = true
        }

        func orderOut() {
            isOrderedIn = false
        }
    }

    final class RecordingDockDrag: SpringboardDockDrag {
        let bundleURL: URL
        let startPoint: CGPoint
        let dropResult: SpringboardDockDropResult
        private(set) var moves: [CGPoint] = []
        private(set) var drops: [CGPoint] = []
        private(set) var cancelCount = 0

        init(bundleURL: URL, startPoint: CGPoint, dropResult: SpringboardDockDropResult) {
            self.bundleURL = bundleURL
            self.startPoint = startPoint
            self.dropResult = dropResult
        }

        func move(to globalPoint: CGPoint) {
            moves.append(globalPoint)
        }

        func drop(at globalPoint: CGPoint) -> SpringboardDockDropResult {
            drops.append(globalPoint)
            return dropResult
        }

        func cancel() {
            cancelCount += 1
        }
    }

    /// A Dock 670 points wide and 94 tall, centred at the bottom of the 1470 × 956 screen; global
    /// coordinates, top-left origin.
    final class RecordingDockDropTarget: SpringboardDockDropTarget {
        static let dockFrame = CGRect(x: 400, y: 862, width: 670, height: 94)

        var dropResult = SpringboardDockDropResult.kept
        private(set) var drags: [RecordingDockDrag] = []
        private(set) var dragWindows: [RecordingDragWindow] = []

        func contains(_ globalPoint: CGPoint) -> Bool {
            Self.dockFrame.contains(globalPoint)
        }

        func makeDragWindow() -> (any SpringboardDragWindow)? {
            let dragWindow = RecordingDragWindow()
            dragWindows.append(dragWindow)
            return dragWindow
        }

        func beginDrag(ofApplicationAt bundleURL: URL, at globalPoint: CGPoint) -> (any SpringboardDockDrag)? {
            let drag = RecordingDockDrag(bundleURL: bundleURL, startPoint: globalPoint, dropResult: dropResult)
            drags.append(drag)
            return drag
        }
    }

    final class EditLog {
        var edits: [LaunchpadEdit] = []
    }

    // MARK: - The springboard

    private static let metrics = SpringboardMetrics(
        SpringboardMetrics.Input(
            screenSize: CGSize(width: 1470, height: 956),
            dockOrientation: .bottom,
            dockThickness: 79,
            notchHeight: 0,
            rowCount: 5,
            columnCount: 7,
            zoomStyle: 0,
            labelLineHeight: 16
        )
    )

    private static func application(_ rowIdentifier: Int64, title: String) -> LaunchpadApplication {
        LaunchpadApplication(
            identifier: LaunchpadItemIdentifier(rowIdentifier: rowIdentifier),
            title: title,
            bundleIdentifier: "com.example.\(rowIdentifier)",
            bookmarkData: nil,
            legacyIconPNGData: nil,
            bundleURL: URL(filePath: "/Applications/\(title).app", directoryHint: .isDirectory)
        )
    }

    private static let calculator = application(10, title: "Calculator")
    private static let terminal = application(11, title: "Terminal")

    private static let layout = LaunchpadLayout(pages: [
        LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 1), items: [
            .application(calculator),
            .folder(LaunchpadFolder(
                identifier: LaunchpadItemIdentifier(rowIdentifier: 50),
                title: "Utilities",
                pages: [
                    LaunchpadFolderPage(
                        identifier: LaunchpadItemIdentifier(rowIdentifier: 51),
                        applications: [application(52, title: "Console"), application(53, title: "Grapher")]
                    ),
                ]
            )),
            .application(terminal),
        ]),
    ])

    /// Container points (bottom-left origin) and the global points (top-left origin) they are.
    private static let pointOnDock = CGPoint(x: 735, y: 40)
    private static let globalPointOnDock = CGPoint(x: 735, y: 916)
    private static let otherPointOnDock = CGPoint(x: 800, y: 50)
    private static let otherGlobalPointOnDock = CGPoint(x: 800, y: 906)
    private static let pointAboveDock = CGPoint(x: 735, y: 400)

    private struct Fixture {
        let interface: SpringboardInterface
        let dockDropTarget: RecordingDockDropTarget
        let editLog: EditLog
    }

    private static func makeFixture(dropResult: SpringboardDockDropResult = .kept) -> Fixture {
        let editLog = EditLog()
        let interface = SpringboardInterface(layout: layout, metrics: metrics, scale: 2, rootLayer: CALayer(), applyEdit: { editLog.edits.append($0) })
        let dockDropTarget = RecordingDockDropTarget()
        dockDropTarget.dropResult = dropResult
        interface.resolveDockDropTarget = { dockDropTarget }
        interface.screenTopLeft = { rectInContainer in
            CGPoint(x: rectInContainer.minX, y: 956 - rectInContainer.maxY)
        }
        return Fixture(interface: interface, dockDropTarget: dockDropTarget, editLog: editLog)
    }

    /// Moves a hundred seconds apart: slow enough for the springboard to respond to every one at once.
    private static func time(_ step: UInt64) -> UInt64 {
        step * 100_000_000_000
    }

    /// Presses the icon of the item at `index` on the first page and moves it far enough to drag it.
    private static func pickUp(itemAt index: Int, in interface: SpringboardInterface) throws -> SpringboardDragSession {
        let itemLayers = try #require(interface.mainPages.currentPageGrid?.itemLayers)
        try #require(itemLayers.indices.contains(index))
        let itemLayer = itemLayers[index]
        // Core Animation lays layers out as it commits them to the screen; here nothing does.
        itemLayer.layoutIfNeeded()
        let iconFrame = itemLayer.convert(itemLayer.iconFrame, to: interface.containerLayer)
        let start = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        _ = interface.handleMouseDown(at: start, timestamp: 0)
        _ = interface.handleMouseDragged(to: CGPoint(x: start.x + 10, y: start.y), timestamp: time(1))
        return try #require(interface.dragSession)
    }

    // MARK: - On the Dock

    @Test("an application dragged onto the Dock is handed to it, riding above the Dock at half opacity")
    func applicationOntoDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)
        #expect(fixture.dockDropTarget.drags.isEmpty)

        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        let dockDrag = try #require(fixture.dockDropTarget.drags.first)
        #expect(fixture.dockDropTarget.drags.count == 1)
        #expect(dockDrag.bundleURL == Self.calculator.bundleURL)
        #expect(dockDrag.startPoint == Self.globalPointOnDock)
        let dragWindow = try #require(fixture.dockDropTarget.dragWindows.first)
        #expect(dragWindow.isOrderedIn)
        #expect(dragSession.itemLayer.superlayer?.superlayer === dragWindow.rootLayer)
        #expect(dragSession.itemLayer.opacity == 0.5)
    }

    @Test("moving on the Dock moves its gap, and nothing in the springboard makes room")
    func movingOnDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)

        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))
        _ = fixture.interface.handleMouseDragged(to: Self.otherPointOnDock, timestamp: Self.time(3))

        let dockDrag = try #require(fixture.dockDropTarget.drags.first)
        #expect(dockDrag.moves == [Self.otherGlobalPointOnDock])
        // Below the pages the icon would otherwise have moved to the end of the page.
        #expect(dragSession.currentIndex == 0)
        #expect(!dragSession.hasRearranged)
    }

    @Test("leaving the Dock closes its gap and brings the icon back into the springboard at full opacity")
    func leavingDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        _ = fixture.interface.handleMouseDragged(to: Self.pointAboveDock, timestamp: Self.time(3))

        let dockDrag = try #require(fixture.dockDropTarget.drags.first)
        #expect(dockDrag.cancelCount == 1)
        #expect(!dragSession.isOverDock)
        #expect(dragSession.itemLayer.superlayer === fixture.interface.containerLayer)
        #expect(dragSession.itemLayer.opacity == 1)
    }

    @Test("coming back onto the Dock hands the application over again, in the same window")
    func comingBackOntoDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        _ = try Self.pickUp(itemAt: 0, in: fixture.interface)

        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))
        _ = fixture.interface.handleMouseDragged(to: Self.pointAboveDock, timestamp: Self.time(3))
        _ = fixture.interface.handleMouseDragged(to: Self.otherPointOnDock, timestamp: Self.time(4))

        #expect(fixture.dockDropTarget.drags.count == 2)
        #expect(fixture.dockDropTarget.drags.last?.startPoint == Self.otherGlobalPointOnDock)
        #expect(fixture.dockDropTarget.dragWindows.count == 1)
    }

    // MARK: - Letting go

    @Test("let go on the Dock, the Dock keeps the application and the icon is back in its place at once")
    func dropOnDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        _ = fixture.interface.handleMouseUp(at: Self.pointOnDock, timestamp: Self.time(3))

        let dockDrag = try #require(fixture.dockDropTarget.drags.first)
        #expect(dockDrag.drops == [Self.globalPointOnDock])
        #expect(dockDrag.cancelCount == 0)
        #expect(fixture.interface.dragSession == nil)
        // The layout is not touched, and the dragged icon is gone rather than sliding home.
        #expect(fixture.editLog.edits.isEmpty)
        #expect(dragSession.itemLayer.superlayer == nil)
        let homeLayer = try #require(fixture.interface.mainPages.currentPageGrid?.itemLayers.first)
        #expect(homeLayer.item?.identifier == Self.calculator.identifier)
        #expect(homeLayer.opacity == 1)
        #expect(fixture.dockDropTarget.dragWindows.first?.isOrderedIn == false)
    }

    @Test("a folder dragged onto the Dock dims, but the Dock gets nothing and letting go writes nothing")
    func folderOntoDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        let dragSession = try Self.pickUp(itemAt: 1, in: fixture.interface)

        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        #expect(fixture.dockDropTarget.drags.isEmpty)
        #expect(dragSession.isOverDock)
        #expect(dragSession.itemLayer.opacity == 0.5)

        _ = fixture.interface.handleMouseUp(at: Self.pointOnDock, timestamp: Self.time(3))

        #expect(fixture.interface.dragSession == nil)
        #expect(fixture.editLog.edits.isEmpty)
    }

    @Test("Escape on the Dock closes its gap and sends the icon home through the springboard")
    func escapeOnDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        _ = fixture.interface.handleKeyDown(keyCode: SpringboardKeyCode.escape, characters: "\u{1B}", modifierFlags: [])

        let dockDrag = try #require(fixture.dockDropTarget.drags.first)
        #expect(dockDrag.cancelCount == 1)
        #expect(dockDrag.drops.isEmpty)
        #expect(dragSession.itemLayer.superlayer === fixture.interface.containerLayer)
        #expect(fixture.editLog.edits.isEmpty)
    }

    @Test("the springboard going while the icon is on the Dock closes the gap")
    func hidingOnDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        _ = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        fixture.interface.prepareForHiding()

        let dockDrag = try #require(fixture.dockDropTarget.drags.first)
        #expect(dockDrag.cancelCount == 1)
        #expect(dockDrag.drops.isEmpty)
    }

    @Test("torn down mid-drag, the springboard leaves no gap and no window behind")
    func tearDownOnDock() throws {
        let fixture = Self.makeFixture()
        _ = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        fixture.interface.tearDown()

        #expect(fixture.dockDropTarget.drags.first?.cancelCount == 1)
        #expect(fixture.dockDropTarget.dragWindows.first?.isOrderedIn == false)
    }

    // MARK: - The Trash

    @Test("let go on the Trash, an application that can be deleted is asked about from its place")
    func trashAsksToDelete() throws {
        let fixture = Self.makeFixture(dropResult: .trash)
        defer { fixture.interface.tearDown() }
        let bundlePath = try #require(Self.calculator.bundleURL?.path)
        fixture.interface.deletabilityByBundlePath[bundlePath] = true
        // Drawn in the springboard, as where no other process shows the popover.
        fixture.interface.makeHostedDeletionConfirmation = { _ in nil }
        _ = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        _ = fixture.interface.handleMouseUp(at: Self.pointOnDock, timestamp: Self.time(3))

        let question = try #require(fixture.interface.deletionQuestion)
        #expect(question.application.identifier == Self.calculator.identifier)
        #expect(question.itemLayer === fixture.interface.mainPages.currentPageGrid?.itemLayers.first)
        #expect(fixture.editLog.edits.isEmpty)
    }

    @Test("let go on the Trash, an application that cannot be deleted is only put back")
    func trashLeavesUndeletable() throws {
        let fixture = Self.makeFixture(dropResult: .trash)
        defer { fixture.interface.tearDown() }
        let bundlePath = try #require(Self.calculator.bundleURL?.path)
        fixture.interface.deletabilityByBundlePath[bundlePath] = false
        _ = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        _ = fixture.interface.handleMouseUp(at: Self.pointOnDock, timestamp: Self.time(3))

        #expect(fixture.interface.deletionQuestion == nil)
        #expect(fixture.interface.dragSession == nil)
        #expect(fixture.editLog.edits.isEmpty)
    }

    @Test("without a Dock to drop onto, a drag to the bottom of the screen is an ordinary drag")
    func noDockDropTarget() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        fixture.interface.resolveDockDropTarget = { nil }
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)

        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        #expect(!dragSession.isOverDock)
        #expect(dragSession.itemLayer.opacity == 1)
        // Below the pages the icon takes the page's last place, as it always has.
        #expect(dragSession.currentIndex == 2)
    }
}
