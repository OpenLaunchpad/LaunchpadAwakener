import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// When a deleted application's icon goes and its page closes up, by macOS 15.5's rules: the uninstall is
/// asked for as the icon starts to play out (`-[Springboard _uninstallRunnable:]`, 15.5 `0x1000976A8`), and
/// the page closes the gap once it has played out (`sub_1000F5C68`), whatever the uninstall has answered.
@Suite("Deleting an application: when the page closes up")
@MainActor
struct SpringboardDeletionTimingTests {
    /// Takes every request and answers only when told to.
    final class RecordingUninstaller: SpringboardApplicationUninstaller {
        var requests: [(bundleURL: URL, completion: @MainActor @Sendable (Bool) -> Void)] = []

        func canUninstall(applicationAt bundleURL: URL) -> Bool {
            true
        }

        func uninstall(applicationAt bundleURL: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
            requests.append((bundleURL, completion))
        }
    }

    final class EditLog {
        var edits: [LaunchpadEdit] = []
    }

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

    private static let applications = ["Calculator", "Chess", "Contacts"].enumerated().map { index, title in
        LaunchpadApplication(
            identifier: LaunchpadItemIdentifier(rowIdentifier: Int64(10 + index)),
            title: title,
            bundleIdentifier: "com.example.\(index)",
            bookmarkData: nil,
            legacyIconPNGData: nil,
            bundleURL: URL(filePath: "/Applications/\(title).app", directoryHint: .isDirectory)
        )
    }

    private static let layout = LaunchpadLayout(pages: [
        LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 1), items: applications.map(LaunchpadItem.application)),
    ])

    private struct Fixture {
        let interface: SpringboardInterface
        let uninstaller: RecordingUninstaller
        let editLog: EditLog
        let pageGrid: SpringboardPageGrid
    }

    /// A springboard whose second icon, Chess, has just been confirmed for deletion.
    private static func makeFixtureDeletingChess() throws -> Fixture {
        let editLog = EditLog()
        let uninstaller = RecordingUninstaller()
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: metrics.input.screenSize)
        let interface = SpringboardInterface(layout: layout, metrics: metrics, scale: 2, rootLayer: rootLayer, applyEdit: { editLog.edits.append($0) })
        interface.resolveApplicationUninstaller = { uninstaller }
        let pageGrid = try #require(interface.mainPages.currentPageGrid)
        interface.presentDeletionPanel(for: pageGrid.itemLayers[1], context: .main)
        try #require(interface.deletionQuestion != nil)
        interface.answerDeletionPanel(.delete)
        return Fixture(interface: interface, uninstaller: uninstaller, editLog: editLog, pageGrid: pageGrid)
    }

    /// Lets Core Animation run the transactions' completion blocks until `isDone` holds.
    private static func wait(until isDone: () -> Bool) async throws {
        for _ in 0..<200 where !isDone() {
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    /// Whether the icon now at `index` of the page sits in the cell at `cellIndex`.
    private static func isLayer(at index: Int, inCell cellIndex: Int, of pageGrid: SpringboardPageGrid) -> Bool {
        let layer = pageGrid.itemLayers[index]
        let cellFrame = pageGrid.cellFrame(at: cellIndex)
        return layer.position == CGPoint(x: cellFrame.midX, y: cellFrame.midY)
    }

    @Test("the uninstall is asked for as the icon starts to play out, as 15 asked")
    func uninstallIsAskedAtOnce() throws {
        let fixture = try Self.makeFixtureDeletingChess()
        defer { fixture.interface.tearDown() }

        #expect(fixture.uninstaller.requests.map(\.bundleURL.lastPathComponent) == ["Chess.app"])
    }

    @Test("the page closes up once the icon has played out, before the uninstall answers, as 15's did")
    func gapClosesBeforeTheAnswer() async throws {
        let fixture = try Self.makeFixtureDeletingChess()
        defer { fixture.interface.tearDown() }

        try await Self.wait { Self.isLayer(at: 2, inCell: 1, of: fixture.pageGrid) }

        #expect(Self.isLayer(at: 2, inCell: 1, of: fixture.pageGrid))
        #expect(fixture.editLog.edits.isEmpty)
    }

    @Test("an uninstall that succeeds takes the application out of the layout")
    func successRemovesTheApplication() async throws {
        let fixture = try Self.makeFixtureDeletingChess()
        defer { fixture.interface.tearDown() }
        try await Self.wait { Self.isLayer(at: 2, inCell: 1, of: fixture.pageGrid) }

        try #require(fixture.uninstaller.requests.first).completion(true)

        #expect(fixture.editLog.edits == [.removeApplication(Self.applications[1].identifier, folder: nil)])
    }

    @Test("an uninstall that succeeds before the icon has played out waits for it to")
    func earlySuccessWaitsForThePlayOut() async throws {
        let fixture = try Self.makeFixtureDeletingChess()
        defer { fixture.interface.tearDown() }

        try #require(fixture.uninstaller.requests.first).completion(true)

        #expect(fixture.editLog.edits.isEmpty)
        try await Self.wait { !fixture.editLog.edits.isEmpty }
        #expect(fixture.editLog.edits == [.removeApplication(Self.applications[1].identifier, folder: nil)])
        #expect(Self.isLayer(at: 2, inCell: 1, of: fixture.pageGrid))
    }

    @Test("a failed uninstall brings the icon back to its place and reopens the gap")
    func failureBringsTheIconBack() async throws {
        let fixture = try Self.makeFixtureDeletingChess()
        defer { fixture.interface.tearDown() }
        try await Self.wait { Self.isLayer(at: 2, inCell: 1, of: fixture.pageGrid) }

        try #require(fixture.uninstaller.requests.first).completion(false)

        #expect(Self.isLayer(at: 2, inCell: 2, of: fixture.pageGrid))
        let chessLayer = fixture.pageGrid.itemLayers[1]
        #expect(chessLayer.opacity == 1)
        #expect(!chessLayer.isBeingDeleted)
        #expect(fixture.editLog.edits.isEmpty)
    }
}
