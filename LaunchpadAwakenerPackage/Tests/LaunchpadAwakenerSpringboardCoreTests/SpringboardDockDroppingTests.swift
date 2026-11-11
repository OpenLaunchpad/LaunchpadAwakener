import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import Metal
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
        /// False where no window above the Dock can be made.
        var makesDragWindows = true
        /// Where the windows' root layers have their origin. A window's root need not share the springboard
        /// window's, so nothing may reach the dragged icon through the roots.
        var dragWindowRootBoundsOrigin = CGPoint.zero
        private(set) var drags: [RecordingDockDrag] = []
        private(set) var dragWindows: [RecordingDragWindow] = []

        func contains(_ globalPoint: CGPoint) -> Bool {
            Self.dockFrame.contains(globalPoint)
        }

        func makeDragWindow() -> (any SpringboardDragWindow)? {
            guard makesDragWindows else { return nil }
            let dragWindow = RecordingDragWindow()
            dragWindow.rootLayer.bounds = CGRect(origin: dragWindowRootBoundsOrigin, size: CGSize(width: 1470, height: 956))
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

    final class RecordingDeletionConfirmation: SpringboardHostedDeletionConfirmation {
        let configuration: SpringboardHostedDeletionConfirmationConfiguration
        var answerHandler: ((SpringboardDeletionChoice) -> Void)?
        var presentationDidFail: (() -> Void)?
        var interruptionHandler: (() -> Void)?

        init(configuration: SpringboardHostedDeletionConfirmationConfiguration) {
            self.configuration = configuration
        }

        func present() {}

        func dismiss() {}
    }

    // MARK: - The springboard

    private static let screenHeight: CGFloat = 956

    private static let metrics = SpringboardMetrics(
        SpringboardMetrics.Input(
            screenSize: CGSize(width: 1470, height: screenHeight),
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
    private static let folderIdentifier = LaunchpadItemIdentifier(rowIdentifier: 50)

    private static let layout = LaunchpadLayout(pages: [
        LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 1), items: [
            .application(calculator),
            .folder(LaunchpadFolder(
                identifier: folderIdentifier,
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
        let rootLayer: CALayer
        let dockDropTarget: RecordingDockDropTarget
        let editLog: EditLog
    }

    private static func makeFixture(dropResult: SpringboardDockDropResult = .kept, position: SpringboardPosition = .firstPage) -> Fixture {
        let editLog = EditLog()
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: metrics.input.screenSize)
        let interface = SpringboardInterface(layout: layout, metrics: metrics, scale: 2, rootLayer: rootLayer, position: position, applyEdit: { editLog.edits.append($0) })
        let dockDropTarget = RecordingDockDropTarget()
        dockDropTarget.dropResult = dropResult
        interface.resolveDockDropTarget = { dockDropTarget }
        interface.screenTopLeft = { rectInContainer in
            CGPoint(x: rectInContainer.minX, y: screenHeight - rectInContainer.maxY)
        }
        return Fixture(interface: interface, rootLayer: rootLayer, dockDropTarget: dockDropTarget, editLog: editLog)
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

    /// Hands `layer` to a renderer drawing off screen and commits it. Core Animation animates changes only
    /// to a layer it has committed, so from here on `layer` animates as one on screen does.
    private static func makeRenderer(committing layer: CALayer) throws -> CARenderer {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        let texture = try #require(device.makeTexture(descriptor: textureDescriptor))
        let renderer = CARenderer(mtlTexture: texture, options: nil)
        renderer.layer = layer
        renderer.bounds = layer.bounds
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        return renderer
    }

    // MARK: - On the Dock

    @Test("a picked-up icon rides above the Dock for the whole drag, as 15's did")
    func ridesAboveDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }

        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointAboveDock, timestamp: Self.time(2))

        // Not yet on the Dock, it may already lie partly over it.
        let dragWindow = try #require(fixture.dockDropTarget.dragWindows.first)
        #expect(fixture.dockDropTarget.dragWindows.count == 1)
        #expect(dragWindow.isOrderedIn)
        #expect(dragSession.itemLayer.superlayer?.superlayer === dragWindow.rootLayer)
        #expect(dragSession.itemLayer.opacity == 1)
        #expect(fixture.dockDropTarget.drags.isEmpty)
    }

    @Test("an application dragged onto the Dock is handed to it at half opacity")
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

    @Test("leaving the Dock closes its gap and brings the icon back to full opacity, still above the Dock")
    func leavingDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        _ = fixture.interface.handleMouseDragged(to: Self.pointAboveDock, timestamp: Self.time(3))

        let dockDrag = try #require(fixture.dockDropTarget.drags.first)
        #expect(dockDrag.cancelCount == 1)
        #expect(!dragSession.isOverDock)
        #expect(dragSession.itemLayer.superlayer?.superlayer === fixture.dockDropTarget.dragWindows.first?.rootLayer)
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

    @Test("Escape on the Dock closes its gap and sends the icon home above everything, as 15's did")
    func escapeOnDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        _ = fixture.interface.handleKeyDown(keyCode: SpringboardKeyCode.escape, characters: "\u{1B}", modifierFlags: [])

        let dockDrag = try #require(fixture.dockDropTarget.drags.first)
        #expect(dockDrag.cancelCount == 1)
        #expect(dockDrag.drops.isEmpty)
        #expect(dragSession.itemLayer.superlayer?.superlayer === fixture.dockDropTarget.dragWindows.first?.rootLayer)
        #expect(dragSession.itemLayer.opacity == 1)
        #expect(fixture.editLog.edits.isEmpty)
    }

    @Test("the springboard going while the icon is on the Dock closes the gap")
    func hidingOnDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        fixture.interface.prepareForHiding()

        let dockDrag = try #require(fixture.dockDropTarget.drags.first)
        #expect(dockDrag.cancelCount == 1)
        #expect(dockDrag.drops.isEmpty)
        // Under the springboard, which fades out as it goes.
        #expect(dragSession.itemLayer.superlayer === fixture.interface.containerLayer)
    }

    @Test("going while a search result on the Dock still leaves the search, the icon fades with the springboard")
    func hidingWhileLeavingSearchOnDock() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)
        // As for a dragged search result until the results have faded out.
        dragSession.isLeavingSearch = true
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))
        #expect(dragSession.isOverDock)

        fixture.interface.prepareForHiding()

        // Back under the springboard's own container, which the exit animation fades out.
        #expect(dragSession.itemLayer.superlayer === fixture.interface.containerLayer)
        #expect(dragSession.itemLayer.opacity == 1)
        #expect(fixture.dockDropTarget.drags.first?.cancelCount == 1)
    }

    @Test("going while a search result is on the Dock, the icon takes its full opacity at once, not over a fade")
    func hidingRestoresOpacityAtOnce() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        let renderer = try Self.makeRenderer(committing: fixture.rootLayer)
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)
        dragSession.isLeavingSearch = true
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))
        CATransaction.flush()

        withExtendedLifetime(renderer) {
            fixture.interface.prepareForHiding()
            CATransaction.flush()
        }

        // An icon brightening while everything else fades out shows for a quarter of a second.
        #expect(dragSession.itemLayer.animation(forKey: "opacity") == nil)
    }

    @Test("leaving the Dock never puts back an icon that is no longer where the Dock had it")
    func leavingDockLeavesRemovedIconAlone() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        fixture.dockDropTarget.makesDragWindows = false
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))
        #expect(dragSession.isOverDock)
        #expect(dragSession.dragWindow == nil)
        dragSession.itemLayer.removeFromSuperlayer()

        fixture.interface.leaveDock()

        #expect(dragSession.itemLayer.superlayer == nil)
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

    @Test("the popover for a release on the Trash hangs from the icon, back in its place")
    func trashPopoverHangsFromIcon() throws {
        let fixture = Self.makeFixture(dropResult: .trash)
        defer { fixture.interface.tearDown() }
        let bundlePath = try #require(Self.calculator.bundleURL?.path)
        fixture.interface.deletabilityByBundlePath[bundlePath] = true
        var presentedConfiguration: SpringboardHostedDeletionConfirmationConfiguration?
        fixture.interface.makeHostedDeletionConfirmation = { configuration in
            presentedConfiguration = configuration
            return RecordingDeletionConfirmation(configuration: configuration)
        }
        _ = try Self.pickUp(itemAt: 0, in: fixture.interface)
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        _ = fixture.interface.handleMouseUp(at: Self.pointOnDock, timestamp: Self.time(3))

        // The page was rebuilt for the drop; the icon is where its laid-out image is.
        let configuration = try #require(presentedConfiguration)
        let homeLayer = try #require(fixture.interface.mainPages.currentPageGrid?.itemLayers.first)
        homeLayer.layoutIfNeeded()
        let iconFrame = homeLayer.imageLayer.convert(homeLayer.imageLayer.bounds, to: fixture.interface.containerLayer)
        #expect(!iconFrame.isEmpty)
        #expect(configuration.screenIconCenter == CGPoint(x: iconFrame.midX, y: Self.screenHeight - iconFrame.midY))
    }

    @Test("let go on the Trash while a folder is open, the application put back on the main page is asked about")
    func trashWithFolderOpen() throws {
        // Opened over the folder, with an application of the main page picked up behind it: what a folder
        // held open by the dragged icon and then left for the Dock in one move leaves behind.
        let fixture = Self.makeFixture(
            dropResult: .trash,
            position: SpringboardPosition(openFolder: SpringboardPosition.OpenFolder(identifier: Self.folderIdentifier, pageIndex: 0))
        )
        defer { fixture.interface.tearDown() }
        #expect(fixture.interface.folderPanel != nil)
        let bundlePath = try #require(Self.calculator.bundleURL?.path)
        fixture.interface.deletabilityByBundlePath[bundlePath] = true
        fixture.interface.makeHostedDeletionConfirmation = { _ in nil }
        let itemLayer = try #require(fixture.interface.mainPages.currentPageGrid?.itemLayers.first)
        itemLayer.layoutIfNeeded()
        let iconFrame = itemLayer.convert(itemLayer.iconFrame, to: fixture.interface.containerLayer)
        let start = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        fixture.interface.beginDrag(
            of: itemLayer,
            context: .main,
            pageIndex: 0,
            itemIndex: 0,
            startLocation: start,
            location: CGPoint(x: start.x + 10, y: start.y),
            timestamp: Self.time(1)
        )
        _ = fixture.interface.handleMouseDragged(to: Self.pointOnDock, timestamp: Self.time(2))

        _ = fixture.interface.handleMouseUp(at: Self.pointOnDock, timestamp: Self.time(3))

        let question = try #require(fixture.interface.deletionQuestion)
        #expect(question.application.identifier == Self.calculator.identifier)
        #expect(question.context == .main)
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
        #expect(dragSession.itemLayer.superlayer === fixture.interface.containerLayer)
        // Below the pages the icon takes the page's last place, as it always has.
        #expect(dragSession.currentIndex == 2)
    }

    @Test("let go on another application, the dragged image flies into the new folder from where it is above the Dock")
    func flightStartsAtDraggedImage() throws {
        let fixture = Self.makeFixture()
        defer { fixture.interface.tearDown() }
        fixture.dockDropTarget.dragWindowRootBoundsOrigin = CGPoint(x: 50, y: 30)
        let dragSession = try Self.pickUp(itemAt: 0, in: fixture.interface)
        let targetLayer = try #require(fixture.interface.mainPages.currentPageGrid?.itemLayers.last)
        targetLayer.layoutIfNeeded()
        let targetIconFrame = targetLayer.convert(targetLayer.iconFrame, to: fixture.interface.containerLayer)
        // The cell's centre over the target's image, which is what holds an icon over another.
        let pointOverTarget = CGPoint(x: targetIconFrame.midX - dragSession.grabOffset.x, y: targetIconFrame.midY - dragSession.grabOffset.y)
        _ = fixture.interface.handleMouseDragged(to: pointOverTarget, timestamp: Self.time(2))
        try #require(dragSession.hoverTarget?.itemLayer === targetLayer)
        let windowContainerLayer = try #require(dragSession.dragWindow?.containerLayer)
        let draggedImageLayer = dragSession.itemLayer.imageLayer
        let draggedImageFrame = draggedImageLayer.convert(draggedImageLayer.bounds, to: windowContainerLayer)

        _ = fixture.interface.handleMouseUp(at: pointOverTarget, timestamp: Self.time(3))

        // The dragged image's copy is the last layer added to the new folder's icon, and flies a tenth of a
        // second after the target's.
        let draggedFlight = try #require(targetLayer.sublayers?.last)
        let expectedFrame = targetLayer.convert(draggedImageFrame, from: fixture.interface.containerLayer)
        #expect(abs(draggedFlight.frame.minX - expectedFrame.minX) < 0.5)
        #expect(abs(draggedFlight.frame.minY - expectedFrame.minY) < 0.5)
        #expect(abs(draggedFlight.frame.width - expectedFrame.width) < 0.5)
    }
}
