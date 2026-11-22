import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// Closing a folder while it is still opening. macOS 15 kept out only a close while one was under way
/// (`-[ECSBPager hideGroup]`, 15.5 `0x100058350`, tests `closingGroup` alone): a press outside the panel
/// (`-[Springboard leftMouseDown:]`, `0x10009216C`) or Escape (`-[Springboard performCancel]`,
/// `0x1000985E8`) while it opened closed it at once, its implicit animations turning back from wherever
/// the opening had got to.
@Suite("Closing a folder while it opens")
@MainActor
struct SpringboardFolderInterruptionTests {
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
            legacyIconPNGData: nil
        )
    }

    private static let folder = LaunchpadFolder(
        identifier: LaunchpadItemIdentifier(rowIdentifier: 50),
        title: "Utilities",
        pages: [
            LaunchpadFolderPage(
                identifier: LaunchpadItemIdentifier(rowIdentifier: 51),
                applications: [application(52, title: "Console"), application(53, title: "Grapher")]
            ),
        ]
    )

    private static let layout = LaunchpadLayout(pages: [
        LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 1), items: [
            .application(application(10, title: "Calculator")),
            .folder(folder),
            .application(application(11, title: "Terminal")),
        ]),
    ])

    /// Near the top left corner of the screen: outside the panel, its title and the search field.
    private static let pointOutsideFolder = CGPoint(x: 40, y: 900)

    /// A springboard with its folder starting to open.
    private static func makeInterfaceOpeningFolder() throws -> (interface: SpringboardInterface, folderPanel: SpringboardFolderPanel) {
        let rootLayer = CALayer()
        rootLayer.frame = CGRect(origin: .zero, size: metrics.input.screenSize)
        let interface = SpringboardInterface(layout: layout, metrics: metrics, scale: 2, rootLayer: rootLayer, applyEdit: { _ in })
        let folderItemLayer = try #require(interface.folderItemLayer(of: folder))
        interface.openFolder(folder, from: folderItemLayer)
        let folderPanel = try #require(interface.folderPanel)
        try #require(interface.isAnimatingFolder)
        try #require(interface.isFolderOpen)
        try #require(!folderPanel.isInsidePanel(pointOutsideFolder))
        try #require(!folderPanel.isOnTitle(pointOutsideFolder))
        return (interface, folderPanel)
    }

    /// Lets Core Animation run the transactions' completion blocks until the folder's panel is gone.
    private static func waitUntilFolderIsGone(in interface: SpringboardInterface) async throws {
        for _ in 0..<200 where interface.folderPanel != nil || interface.isAnimatingFolder {
            CATransaction.flush()
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    @Test("a press outside a folder while it opens closes it, as 15's did")
    func pressOutsideClosesOpeningFolder() throws {
        let (interface, _) = try Self.makeInterfaceOpeningFolder()
        defer { interface.tearDown() }

        _ = interface.handleMouseDown(at: Self.pointOutsideFolder, timestamp: 0)
        _ = interface.handleMouseUp(at: Self.pointOutsideFolder, timestamp: 1)

        // Closing, from wherever the opening had got to.
        #expect(interface.folderPanel != nil)
        #expect(!interface.isFolderOpen)
        #expect(interface.isAnimatingFolder)
    }

    @Test("Escape while a folder opens closes it, as 15's did")
    func escapeClosesOpeningFolder() throws {
        let (interface, _) = try Self.makeInterfaceOpeningFolder()
        defer { interface.tearDown() }

        let action = interface.handleKeyDown(keyCode: SpringboardKeyCode.escape, characters: "\u{1B}", modifierFlags: [])

        #expect(!interface.isFolderOpen)
        // The folder goes, not the springboard.
        guard case .none = action else {
            Issue.record("Escape while the folder opened did \(action)")
            return
        }
    }

    @Test("a press inside the panel while the folder opens is let be")
    func pressInsideOpeningFolderIsIgnored() throws {
        let (interface, folderPanel) = try Self.makeInterfaceOpeningFolder()
        defer { interface.tearDown() }
        let panelFrame = folderPanel.folderMetrics.panelFrame
        let folderOrigin = folderPanel.folderLayer.frame.origin
        let pointInPanel = CGPoint(x: folderOrigin.x + panelFrame.midX, y: folderOrigin.y + panelFrame.midY)
        try #require(folderPanel.isInsidePanel(pointInPanel))

        _ = interface.handleMouseDown(at: pointInPanel, timestamp: 0)
        _ = interface.handleMouseUp(at: pointInPanel, timestamp: 1)

        #expect(interface.isFolderOpen)
    }

    @Test("an opening cut short never finishes once the folder is closing")
    func interruptedOpeningDoesNotFinish() async throws {
        let (interface, folderPanel) = try Self.makeInterfaceOpeningFolder()
        defer { interface.tearDown() }

        _ = interface.handleMouseDown(at: Self.pointOutsideFolder, timestamp: 0)
        _ = interface.handleMouseUp(at: Self.pointOutsideFolder, timestamp: 1)
        try #require(!interface.isFolderOpen)
        try await Self.waitUntilFolderIsGone(in: interface)

        #expect(interface.folderPanel == nil)
        #expect(!interface.isAnimatingFolder)
        // The opening's last step fades the page dots in; closing had faded them out.
        #expect(folderPanel.pages.pagerControlLayer.opacity == 0)
    }

    @Test("once a folder cut short has closed, it opens again")
    func folderOpensAgainAfterInterruption() async throws {
        let (interface, _) = try Self.makeInterfaceOpeningFolder()
        defer { interface.tearDown() }
        _ = interface.handleMouseDown(at: Self.pointOutsideFolder, timestamp: 0)
        _ = interface.handleMouseUp(at: Self.pointOutsideFolder, timestamp: 1)
        try await Self.waitUntilFolderIsGone(in: interface)
        try #require(interface.folderPanel == nil)
        let folderItemLayer = try #require(interface.folderItemLayer(of: Self.folder))

        interface.openFolder(Self.folder, from: folderItemLayer)

        #expect(interface.isFolderOpen)
    }
}
