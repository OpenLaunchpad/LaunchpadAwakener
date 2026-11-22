import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// Dragging an application out of an open folder, by macOS 15.5's rules
/// (`-[ECSBCloseGroupDragState beginTransition]`, 15.5 `0x10011FE08`): the folder goes only once empty, or
/// when it was made moments before and the drag leaves it one application (`-[ECSBGroup canBeRemoved]`,
/// `0x1000A1DA0`); a folder jiggling hands its jiggling on to the main pages.
@Suite("Dragging out of an open folder")
@MainActor
struct SpringboardFolderExitTests {
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

    private static let console = application(52, title: "Console")
    private static let grapher = application(53, title: "Grapher")

    private static let folder = LaunchpadFolder(
        identifier: LaunchpadItemIdentifier(rowIdentifier: 50),
        title: "Utilities",
        pages: [LaunchpadFolderPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 51), applications: [console, grapher])]
    )

    private static let layout = LaunchpadLayout(pages: [
        LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 1), items: [
            .application(application(10, title: "Calculator")),
            .folder(folder),
            .application(application(11, title: "Terminal")),
        ]),
    ])

    final class EditLog {
        var edits: [LaunchpadEdit] = []
    }

    /// Near the top of the screen, well above the folder's panel.
    private static let pointAbovePanel = CGPoint(x: 300, y: 880)

    /// Moves a hundred seconds apart: slow enough for the springboard to respond to every one at once.
    private static func time(_ step: UInt64) -> UInt64 {
        step * 100_000_000_000
    }

    /// Lets Core Animation run the transactions' completion blocks, and the springboard its timers, until
    /// `isDone` holds.
    private static func wait(until isDone: () -> Bool) async throws {
        for _ in 0..<300 where !isDone() {
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// A springboard with the folder open, `isNew` as a quick drop's folder opened by itself is.
    private static func makeInterfaceWithFolderOpen(isNew: Bool) async throws -> (SpringboardInterface, EditLog) {
        let editLog = EditLog()
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: metrics.input.screenSize)
        let interface = SpringboardInterface(layout: layout, metrics: metrics, scale: 2, rootLayer: rootLayer, applyEdit: { editLog.edits.append($0) })
        let folderItemLayer = try #require(interface.folderItemLayer(of: folder))
        interface.openFolder(folder, from: folderItemLayer, isNew: isNew)
        try await wait { !interface.isAnimatingFolder }
        try #require(interface.isFolderOpen && !interface.isAnimatingFolder)
        return (interface, editLog)
    }

    /// Picks up Console in the open folder and carries it above the panel, out of the folder.
    private static func dragConsoleOutOfFolder(in interface: SpringboardInterface) throws -> SpringboardDragSession {
        let folderPanel = try #require(interface.folderPanel)
        let itemLayer = try #require(folderPanel.pages.currentPageGrid?.itemLayers.first)
        itemLayer.layoutIfNeeded()
        let iconFrame = itemLayer.convert(itemLayer.iconFrame, to: interface.containerLayer)
        let start = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        _ = interface.handleMouseDown(at: start, timestamp: 0)
        _ = interface.handleMouseDragged(to: CGPoint(x: start.x + 10, y: start.y), timestamp: time(1))
        let dragSession = try #require(interface.dragSession)
        _ = interface.handleMouseDragged(to: pointAbovePanel, timestamp: time(2))
        try #require(dragSession.context == .main)
        return dragSession
    }

    private static func folders(in arrangement: [LaunchpadItem]) -> [LaunchpadItemIdentifier] {
        arrangement.compactMap { item in
            if case .folder(let folder) = item { folder.identifier } else { nil }
        }
    }

    @Test("dragging one of two applications out of a folder leaves a folder of one, as 15 did")
    func folderOfOneStays() async throws {
        let (interface, editLog) = try await Self.makeInterfaceWithFolderOpen(isNew: false)
        defer { interface.tearDown() }

        let dragSession = try Self.dragConsoleOutOfFolder(in: interface)

        #expect(Self.folders(in: dragSession.arrangement) == [Self.folder.identifier])
        _ = interface.handleMouseUp(at: Self.pointAbovePanel, timestamp: Self.time(3))
        try await Self.wait { interface.dragSession == nil }
        let edit = try #require(editLog.edits.last)
        guard case .moveOutOfFolder(let itemIdentifier, _, _) = edit else {
            Issue.record("The drop wrote \(edit)")
            return
        }
        #expect(itemIdentifier == Self.console.identifier)
    }

    @Test("dragging one of two applications out of a folder a quick drop just made dissolves it")
    func newFolderDissolves() async throws {
        let (interface, editLog) = try await Self.makeInterfaceWithFolderOpen(isNew: true)
        defer { interface.tearDown() }

        let dragSession = try Self.dragConsoleOutOfFolder(in: interface)

        #expect(Self.folders(in: dragSession.arrangement).isEmpty)
        #expect(dragSession.arrangement.contains { $0.identifier == Self.grapher.identifier })
        _ = interface.handleMouseUp(at: Self.pointAbovePanel, timestamp: Self.time(3))
        try await Self.wait { interface.dragSession == nil }
        let edit = try #require(editLog.edits.last)
        guard case .dissolvingFolder(let applicationIdentifier, let innerEdit) = edit, case .moveOutOfFolder = innerEdit else {
            Issue.record("The drop wrote \(edit)")
            return
        }
        #expect(applicationIdentifier == Self.console.identifier)
    }

    @Test("dragging an application out of a jiggling folder leaves the main pages jiggling, as 15 did")
    func jigglingCarriesOn() async throws {
        let (interface, _) = try await Self.makeInterfaceWithFolderOpen(isNew: false)
        defer { interface.tearDown() }
        let folderPanel = try #require(interface.folderPanel)
        folderPanel.pages.isJiggling = true

        _ = try Self.dragConsoleOutOfFolder(in: interface)

        #expect(interface.mainPages.isJiggling)
    }

    @Test("past a folder's last page, a held icon gets a new page of the folder, as 15's did")
    func newFolderPage() async throws {
        // 15 added a page to the folder as to the main pages (`-[ECSBGroup addPageForPager:]`, 15.5
        // `0x1000A31CC`).
        let (interface, editLog) = try await Self.makeInterfaceWithFolderOpen(isNew: false)
        defer { interface.tearDown() }
        let folderPanel = try #require(interface.folderPanel)
        let itemLayer = try #require(folderPanel.pages.currentPageGrid?.itemLayers.first)
        itemLayer.layoutIfNeeded()
        let iconFrame = itemLayer.convert(itemLayer.iconFrame, to: interface.containerLayer)
        let start = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        _ = interface.handleMouseDown(at: start, timestamp: 0)
        _ = interface.handleMouseDragged(to: CGPoint(x: start.x + 10, y: start.y), timestamp: Self.time(1))
        let dragSession = try #require(interface.dragSession)

        interface.turnPageWhileDragging(direction: 1, isFirstTurn: false)

        #expect(folderPanel.pages.pageGrids.count == 2)
        #expect(dragSession.context == .folder)
        #expect(dragSession.pageIndex == 1)
        _ = interface.handleMouseUp(at: CGPoint(x: start.x + 10, y: start.y), timestamp: Self.time(2))
        try await Self.wait { interface.dragSession == nil }
        #expect(editLog.edits.last == .moveToNewFolderPage(Self.console.identifier, folder: Self.folder.identifier))
    }

    /// Picks up Console in the open folder, without moving it out of its cell.
    private static func pickUpConsole(in interface: SpringboardInterface) throws -> SpringboardDragSession {
        let folderPanel = try #require(interface.folderPanel)
        let itemLayers = try #require(folderPanel.pages.currentPageGrid?.itemLayers)
        itemLayers.forEach { $0.layoutIfNeeded() }
        let iconFrame = itemLayers[0].convert(itemLayers[0].iconFrame, to: interface.containerLayer)
        let start = CGPoint(x: iconFrame.midX, y: iconFrame.midY)
        _ = interface.handleMouseDown(at: start, timestamp: 0)
        _ = interface.handleMouseDragged(to: CGPoint(x: start.x + 10, y: start.y), timestamp: time(1))
        return try #require(interface.dragSession)
    }

    @Test("Escape after moving an icon about in its open folder closes the folder, as 15's did")
    func escapeAfterRearrangingClosesFolder() async throws {
        let (interface, _) = try await Self.makeInterfaceWithFolderOpen(isNew: false)
        defer { interface.tearDown() }
        let dragSession = try Self.pickUpConsole(in: interface)
        let folderPanel = try #require(interface.folderPanel)
        let grapherLayer = try #require(folderPanel.pages.currentPageGrid?.itemLayers.last)
        let grapherIcon = grapherLayer.convert(grapherLayer.iconFrame, to: interface.containerLayer)
        let pastGrapher = CGPoint(x: grapherIcon.midX + 20 - dragSession.grabOffset.x, y: grapherIcon.midY - dragSession.grabOffset.y)
        _ = interface.handleMouseDragged(to: pastGrapher, timestamp: Self.time(2))
        try #require(dragSession.currentIndex == 1)

        _ = interface.handleKeyDown(keyCode: SpringboardKeyCode.escape, characters: "\u{1B}", modifierFlags: [])

        #expect(!interface.isFolderOpen)
    }

    @Test("Escape before an icon has moved in its open folder sends it back there, the folder staying open")
    func escapeBeforeRearrangingKeepsFolder() async throws {
        let (interface, _) = try await Self.makeInterfaceWithFolderOpen(isNew: false)
        defer { interface.tearDown() }
        _ = try Self.pickUpConsole(in: interface)

        _ = interface.handleKeyDown(keyCode: SpringboardKeyCode.escape, characters: "\u{1B}", modifierFlags: [])

        #expect(interface.isFolderOpen)
    }

    @Test("dragging out of a folder that was still: the main pages stay still")
    func stillnessCarriesOn() async throws {
        let (interface, _) = try await Self.makeInterfaceWithFolderOpen(isNew: false)
        defer { interface.tearDown() }

        _ = try Self.dragConsoleOutOfFolder(in: interface)

        #expect(!interface.mainPages.isJiggling)
    }
}
