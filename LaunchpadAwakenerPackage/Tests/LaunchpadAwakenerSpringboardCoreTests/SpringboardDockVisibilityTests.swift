import CoreGraphics
@testable import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// macOS 15 kept the Dock on screen while the springboard showed, and slid it away while a folder was
/// open: `-[LPSpringboard setVisible:slow:forGaming:reason:]` (15.5 `0x1000B0434`) set the Dock's show
/// override, and `-[Springboard groupShownForItem:atIndex:]` (`0x100093500`) and `groupHiddenForItem:`
/// (`0x1000935A4`) forced it hidden and let it go, as the folder's panel started to open and to close.
@Suite("The Dock while the springboard shows")
@MainActor
struct SpringboardDockVisibilityTests {
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

    private static let folder = LaunchpadFolder(
        identifier: LaunchpadItemIdentifier(rowIdentifier: 50),
        title: "Utilities",
        pages: [
            LaunchpadFolderPage(
                identifier: LaunchpadItemIdentifier(rowIdentifier: 51),
                applications: [
                    LaunchpadApplication(
                        identifier: LaunchpadItemIdentifier(rowIdentifier: 52),
                        title: "Calculator",
                        bundleIdentifier: "com.example.calculator",
                        bookmarkData: nil,
                        legacyIconPNGData: nil
                    ),
                    LaunchpadApplication(
                        identifier: LaunchpadItemIdentifier(rowIdentifier: 53),
                        title: "Terminal",
                        bundleIdentifier: "com.example.terminal",
                        bookmarkData: nil,
                        legacyIconPNGData: nil
                    ),
                ]
            ),
        ]
    )

    private static let layout = LaunchpadLayout(pages: [
        LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 1), items: [.folder(folder)]),
    ])

    private static func makeInterface(position: SpringboardPosition = .firstPage) -> SpringboardInterface {
        SpringboardInterface(layout: layout, metrics: metrics, scale: 2, rootLayer: CALayer(), position: position, applyEdit: { _ in })
    }

    /// Reopened over the folder, the way a springboard left with the folder open comes back.
    private static func makeInterfaceWithFolderOpen() -> SpringboardInterface {
        makeInterface(position: SpringboardPosition(openFolder: SpringboardPosition.OpenFolder(identifier: folder.identifier, pageIndex: 0)))
    }

    // MARK: - What the Dock is asked to do

    @Test("the Dock is left as the user set it while the springboard is away")
    func awayLeavesTheDockAlone() {
        #expect(SpringboardDockVisibility(isShowing: false, isHiding: false, isFolderOpen: false) == .unchanged)
        #expect(SpringboardDockVisibility(isShowing: false, isHiding: false, isFolderOpen: true) == .unchanged)
    }

    @Test("the Dock is kept on screen over the pages")
    func pagesKeepTheDock() {
        #expect(SpringboardDockVisibility(isShowing: true, isHiding: false, isFolderOpen: false) == .keptVisible)
    }

    @Test("an open folder slides the Dock away")
    func openFolderHidesTheDock() {
        #expect(SpringboardDockVisibility(isShowing: true, isHiding: false, isFolderOpen: true) == .hidden)
    }

    @Test("the Dock comes back as the springboard starts to go, and stays until it has gone")
    func goingBringsTheDockBack() {
        // 15 let the folder's hold go as its exit animation began (15.5 `0x10009173C`) and the show
        // override only once that animation had ended (`0x1000B079C`).
        #expect(SpringboardDockVisibility(isShowing: false, isHiding: true, isFolderOpen: true) == .keptVisible)
        #expect(SpringboardDockVisibility(isShowing: false, isHiding: true, isFolderOpen: false) == .keptVisible)
    }

    // MARK: - When a folder counts as open

    @Test("a folder counts as open from the moment it starts to open")
    func openingFolderIsOpen() throws {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        var reportCount = 0
        interface.folderOpennessDidChange = { reportCount += 1 }
        let folderItemLayer = try #require(interface.folderItemLayer(of: Self.folder))
        #expect(!interface.isFolderOpen)

        interface.openFolder(Self.folder, from: folderItemLayer)

        #expect(interface.isAnimatingFolder)
        #expect(interface.isFolderOpen)
        #expect(reportCount == 1)
    }

    @Test("a springboard reopened over a folder starts with it open")
    func reopenedFolderIsOpen() {
        let interface = Self.makeInterfaceWithFolderOpen()
        defer { interface.tearDown() }

        #expect(interface.folderPanel != nil)
        #expect(interface.isFolderOpen)
    }

    @Test("a folder counts as closed from the moment it starts to close")
    func closingFolderIsClosed() {
        let interface = Self.makeInterfaceWithFolderOpen()
        defer { interface.tearDown() }
        var reportCount = 0
        interface.folderOpennessDidChange = { reportCount += 1 }

        interface.closeFolder()

        // Still on screen, closing.
        #expect(interface.folderPanel != nil)
        #expect(!interface.isFolderOpen)
        #expect(reportCount == 1)
    }

    @Test("a folder closed without animation counts as closed, and is reported once")
    func folderClosedAtOnceIsClosed() {
        let interface = Self.makeInterfaceWithFolderOpen()
        defer { interface.tearDown() }
        var reportCount = 0
        interface.folderOpennessDidChange = { reportCount += 1 }

        interface.closeFolder(animated: false)

        #expect(interface.folderPanel == nil)
        #expect(!interface.isFolderOpen)
        #expect(reportCount == 1)
    }

    @Test("a folder taken away at once counts as closed")
    func dismissedFolderIsClosed() {
        let interface = Self.makeInterfaceWithFolderOpen()
        defer { interface.tearDown() }
        var reportCount = 0
        interface.folderOpennessDidChange = { reportCount += 1 }

        interface.dismissFolderImmediately()

        #expect(!interface.isFolderOpen)
        #expect(reportCount == 1)
    }

    @Test("a folder that the stored layout no longer has counts as closed")
    func folderGoneFromTheLayoutIsClosed() {
        let interface = Self.makeInterfaceWithFolderOpen()
        defer { interface.tearDown() }
        var reportCount = 0
        interface.folderOpennessDidChange = { reportCount += 1 }

        interface.replaceLayout(LaunchpadLayout(pages: [LaunchpadPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 1), items: [])]))

        #expect(interface.folderPanel == nil)
        #expect(!interface.isFolderOpen)
        #expect(reportCount == 1)
    }
}
