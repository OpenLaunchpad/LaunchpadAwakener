import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// Where a dragged icon goes as it passes over the others, by macOS 15.5's rules
/// (`-[ECSBDragCapture _dragStateForEvent:itemFrame:]`, 15.5 `0x1000B50B0`): reaching another icon's picture
/// holds the dragged one over it, and from then on every move asks again whether to make room, so the icon
/// held over gives way as soon as the dragged one is more than a whole cell from its own place.
@Suite("Making room while dragging")
@MainActor
struct SpringboardDragRearrangingTests {
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

    private static let titles = ["Calculator", "Calendar", "Chess", "Contacts", "Dictionary", "FaceTime", "Maps"]

    /// One full row of applications on the first page.
    private static let layout = LaunchpadLayout(pages: [
        LaunchpadPage(
            identifier: LaunchpadItemIdentifier(rowIdentifier: 1),
            items: titles.enumerated().map { index, title in
                .application(LaunchpadApplication(
                    identifier: LaunchpadItemIdentifier(rowIdentifier: Int64(10 + index)),
                    title: title,
                    bundleIdentifier: "com.example.\(index)",
                    bookmarkData: nil,
                    legacyIconPNGData: nil,
                    bundleURL: URL(filePath: "/Applications/\(title).app", directoryHint: .isDirectory)
                ))
            }
        ),
    ])

    private static func makeInterface() -> SpringboardInterface {
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: metrics.input.screenSize)
        return SpringboardInterface(layout: layout, metrics: metrics, scale: 2, rootLayer: rootLayer, applyEdit: { _ in })
    }

    /// Moves a hundred seconds apart: slow enough for the springboard to respond to every one at once.
    private static func time(_ step: UInt64) -> UInt64 {
        step * 100_000_000_000
    }

    /// Presses the first icon and moves it far enough to drag it, staying in its own cell.
    private static func pickUpFirstIcon(in interface: SpringboardInterface) throws -> SpringboardDragSession {
        let itemLayers = try #require(interface.mainPages.currentPageGrid?.itemLayers)
        itemLayers.forEach { $0.layoutIfNeeded() }
        let iconFrame = try iconFrame(of: 0, in: interface)
        let start = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        _ = interface.handleMouseDown(at: start, timestamp: 0)
        _ = interface.handleMouseDragged(to: CGPoint(x: start.x + 10, y: start.y), timestamp: time(1))
        return try #require(interface.dragSession)
    }

    /// The picture of the icon first on the page at `index`, in the container.
    private static func iconFrame(of index: Int, in interface: SpringboardInterface) throws -> CGRect {
        let itemLayers = try #require(interface.mainPages.currentPageGrid?.itemLayers)
        let itemLayer = itemLayers[index]
        itemLayer.layoutIfNeeded()
        return itemLayer.convert(itemLayer.iconFrame, to: interface.containerLayer)
    }

    /// Moves the pointer so that the dragged cell's centre — what 15 measured from — lands on `cellCentre`.
    private static func moveDraggedCell(to cellCentre: CGPoint, in interface: SpringboardInterface, dragSession: SpringboardDragSession, step: UInt64) {
        let pointer = CGPoint(x: cellCentre.x - dragSession.grabOffset.x, y: cellCentre.y - dragSession.grabOffset.y)
        _ = interface.handleMouseDragged(to: pointer, timestamp: time(step))
    }

    private static func itemTitles(of dragSession: SpringboardDragSession) -> [String] {
        dragSession.arrangement.map { item in
            if case .application(let application) = item { application.title } else { "" }
        }
    }

    @Test("reaching another icon's picture holds the dragged one over it rather than making room")
    func reachingIconHoldsOverIt() throws {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        let dragSession = try Self.pickUpFirstIcon(in: interface)
        let neighbourIcon = try Self.iconFrame(of: 1, in: interface)

        Self.moveDraggedCell(to: CGPoint(x: neighbourIcon.midX, y: neighbourIcon.midY), in: interface, dragSession: dragSession, step: 2)

        #expect(dragSession.hoverTarget?.index == 1)
        #expect(dragSession.currentIndex == 0)
    }

    @Test("an icon held over gives way once the dragged one passes its middle, as 15's did")
    func heldOverIconGivesWayPastItsMiddle() throws {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        let dragSession = try Self.pickUpFirstIcon(in: interface)
        let neighbourIcon = try Self.iconFrame(of: 1, in: interface)
        Self.moveDraggedCell(to: CGPoint(x: neighbourIcon.midX, y: neighbourIcon.midY), in: interface, dragSession: dragSession, step: 2)
        try #require(dragSession.hoverTarget?.index == 1)

        // Still on the neighbour's picture, past its middle: more than a whole cell from the dragged icon's place.
        Self.moveDraggedCell(to: CGPoint(x: neighbourIcon.midX + 20, y: neighbourIcon.midY), in: interface, dragSession: dragSession, step: 3)

        #expect(dragSession.hoverTarget == nil)
        #expect(dragSession.currentIndex == 1)
        #expect(Self.itemTitles(of: dragSession).prefix(2) == ["Calendar", "Calculator"])
    }

    @Test("short of the middle of the icon held over, the dragged one stays held over it")
    func heldOverIconStaysShortOfItsMiddle() throws {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        let dragSession = try Self.pickUpFirstIcon(in: interface)
        let neighbourIcon = try Self.iconFrame(of: 1, in: interface)
        Self.moveDraggedCell(to: CGPoint(x: neighbourIcon.midX, y: neighbourIcon.midY), in: interface, dragSession: dragSession, step: 2)
        try #require(dragSession.hoverTarget?.index == 1)

        Self.moveDraggedCell(to: CGPoint(x: neighbourIcon.midX - 20, y: neighbourIcon.midY), in: interface, dragSession: dragSession, step: 3)

        #expect(dragSession.hoverTarget?.index == 1)
        #expect(dragSession.currentIndex == 0)
    }

    @Test("off the picture held over but still in its cell, the dragged icon stays held over it, as in 15")
    func holdOutlastsThePictureInItsCell() throws {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        let dragSession = try Self.pickUpFirstIcon(in: interface)
        let neighbourIcon = try Self.iconFrame(of: 1, in: interface)
        Self.moveDraggedCell(to: CGPoint(x: neighbourIcon.midX, y: neighbourIcon.midY), in: interface, dragSession: dragSession, step: 2)
        try #require(dragSession.hoverTarget?.index == 1)

        // Just under the picture, on the near half of the cell: 15 only ended a hold by making room, by
        // another cell or by an edge.
        Self.moveDraggedCell(to: CGPoint(x: neighbourIcon.midX - 20, y: neighbourIcon.minY - 5), in: interface, dragSession: dragSession, step: 3)

        #expect(dragSession.hoverTarget?.index == 1)
        #expect(dragSession.currentIndex == 0)
    }

    @Test("moving from the icon held over onto another one makes room rather than holding over the new one")
    func anotherIconMakesRoomFirst() throws {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        let dragSession = try Self.pickUpFirstIcon(in: interface)
        let neighbourIcon = try Self.iconFrame(of: 1, in: interface)
        let fartherIcon = try Self.iconFrame(of: 3, in: interface)
        Self.moveDraggedCell(to: CGPoint(x: neighbourIcon.midX, y: neighbourIcon.midY), in: interface, dragSession: dragSession, step: 2)
        try #require(dragSession.hoverTarget?.index == 1)

        Self.moveDraggedCell(to: CGPoint(x: fartherIcon.midX, y: fartherIcon.midY), in: interface, dragSession: dragSession, step: 3)

        // 15 let go of the old target and looked for a new place; only a later move could hold over another.
        #expect(dragSession.hoverTarget == nil)
        #expect(dragSession.currentIndex == 3)
        #expect(Self.itemTitles(of: dragSession).prefix(4) == ["Calendar", "Chess", "Contacts", "Calculator"])
    }

    @Test("back on its own cell, the dragged icon no longer holds over the other")
    func ownCellEndsHold() throws {
        // 15 kept the hold there, and letting go made a folder with an icon the pointer had left; the
        // replica lets go of it instead.
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        let dragSession = try Self.pickUpFirstIcon(in: interface)
        let ownIcon = try Self.iconFrame(of: 0, in: interface)
        let neighbourIcon = try Self.iconFrame(of: 1, in: interface)
        Self.moveDraggedCell(to: CGPoint(x: neighbourIcon.midX, y: neighbourIcon.midY), in: interface, dragSession: dragSession, step: 2)
        try #require(dragSession.hoverTarget?.index == 1)

        Self.moveDraggedCell(to: CGPoint(x: ownIcon.midX, y: ownIcon.midY), in: interface, dragSession: dragSession, step: 3)

        #expect(dragSession.hoverTarget == nil)
        #expect(dragSession.currentIndex == 0)
    }
}
