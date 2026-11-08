import CoreGraphics
@testable import LaunchpadAwakenerPayloadCore
import Metal
import QuartzCore
import Testing

/// The springboard's own layers, built without the Dock: its layer classes are missing here, so the pages
/// stay empty and the background is the stand-in blur, but the geometry is the springboard's own.
@Suite("Springboard layers")
@MainActor
struct SpringboardInterfaceTests {
    private static let screenSize = CGSize(width: 1470, height: 956)

    private static let metrics = SpringboardMetrics(
        SpringboardMetrics.Input(
            screenSize: screenSize,
            dockOrientation: .bottom,
            dockThickness: 59,
            notchHeight: 0,
            rowCount: 5,
            columnCount: 7,
            zoomStyle: 0,
            labelLineHeight: 16
        )
    )

    private static func makeInterface(rootLayer: CALayer) -> SpringboardInterface {
        SpringboardInterface(layout: .empty, metrics: metrics, scale: 2, rootLayer: rootLayer, applyEdit: { _ in })
    }

    /// An open folder of one application named `title`.
    private static func makeFolderPanel(title: String) -> SpringboardFolderPanel {
        let application = LaunchpadApplication(
            identifier: LaunchpadItemIdentifier(rowIdentifier: 51),
            title: "Calculator",
            bundleIdentifier: "com.apple.calculator",
            bookmarkData: nil,
            legacyIconPNGData: nil
        )
        let folder = LaunchpadFolder(
            identifier: LaunchpadItemIdentifier(rowIdentifier: 50),
            title: title,
            pages: [LaunchpadFolderPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 52), applications: [application])]
        )
        return SpringboardFolderPanel(folder: folder, metrics: metrics, scale: 2) { _ in }
    }

    /// `point`, a point in the folder layer, where the springboard hit-tests: in the folder layer's superlayer.
    private static func springboardPoint(_ point: CGPoint, in folderPanel: SpringboardFolderPanel) -> CGPoint {
        CGPoint(x: point.x + folderPanel.folderLayer.frame.minX, y: point.y + folderPanel.folderLayer.frame.minY)
    }

    @Test("the background covers the screen even when the window's root layer has no size yet")
    func backgroundCoversScreenBeforeRootLayerIsSized() throws {
        // The Dock's window gives its root layer no size by the time the springboard is built.
        let interface = Self.makeInterface(rootLayer: CALayer())
        defer { interface.tearDown() }

        let background = try #require(interface.background)
        #expect(interface.containerLayer.bounds.size == Self.screenSize)
        #expect(background.layer.frame == CGRect(origin: .zero, size: Self.screenSize))
    }

    @Test("an icon moved to a cell while scaled down keeps the cell's size")
    func movingScaledIconKeepsCellSize() {
        // A dissolving folder's icon is at a tenth of its size when the page closes up around it.
        let iconLayer = CALayer()
        iconLayer.frame = CGRect(x: 0, y: 0, width: 193, height: 169)
        iconLayer.transform = CATransform3DMakeScale(0.1, 0.1, 1)
        let cellFrame = CGRect(x: 1158, y: 677, width: 193, height: 169)

        iconLayer.setUntransformedFrame(cellFrame)

        #expect(iconLayer.bounds.size == cellFrame.size)
        #expect(iconLayer.position == CGPoint(x: cellFrame.midX, y: cellFrame.midY))
    }

    @Test("a closing folder leaves alone the icon being dragged out of it")
    func closingFolderSkipsDraggedIcon() {
        // A folder's grid still lists the icon a drag took out; that icon now hangs off the container.
        let containerLayer = CALayer()
        let folderLayer = CALayer()
        let gridLayer = CALayer()
        let firstIconLayer = CALayer()
        let draggedIconLayer = CALayer()
        let lastIconLayer = CALayer()
        containerLayer.addSublayer(folderLayer)
        folderLayer.addSublayer(gridLayer)
        gridLayer.addSublayer(firstIconLayer)
        gridLayer.addSublayer(lastIconLayer)
        containerLayer.addSublayer(draggedIconLayer)

        let closingLayers = SpringboardFolderPanel.itemLayersInPanel([firstIconLayer, draggedIconLayer, lastIconLayer], folderLayer: folderLayer)

        #expect(closingLayers.map(ObjectIdentifier.init) == [firstIconLayer, lastIconLayer].map(ObjectIdentifier.init))
    }

    @Test("a press beside an open folder's title does not start renaming it")
    func pressBesideTitleDoesNotStartRenaming() {
        // 15 took a press only on the title itself; the box 200 points wider was the editor's, hidden
        // until renaming began.
        let folderPanel = Self.makeFolderPanel(title: "Utilities")
        let titleFrame = folderPanel.titleLayer.frame

        #expect(folderPanel.isOnTitle(Self.springboardPoint(CGPoint(x: titleFrame.midX, y: titleFrame.midY), in: folderPanel)))
        #expect(!folderPanel.isOnTitle(Self.springboardPoint(CGPoint(x: titleFrame.maxX + 100, y: titleFrame.midY), in: folderPanel)))
    }

    @Test("while a folder is renamed, its editor keeps presses up to 200 points either side of the title")
    func editorKeepsPressesBesideTitle() {
        let folderPanel = Self.makeFolderPanel(title: "Utilities")
        let titleFrame = folderPanel.titleLayer.frame

        #expect(folderPanel.isInTitleEditor(Self.springboardPoint(CGPoint(x: titleFrame.minX - 100, y: titleFrame.midY), in: folderPanel)))
        #expect(folderPanel.isInTitleEditor(Self.springboardPoint(CGPoint(x: titleFrame.maxX + 100, y: titleFrame.midY), in: folderPanel)))
        #expect(!folderPanel.isInTitleEditor(Self.springboardPoint(CGPoint(x: titleFrame.maxX + 250, y: titleFrame.midY), in: folderPanel)))
    }

    /// Text the springboard changes in front of the user: as it is typed, or once a new name is stored.
    enum ChangingText: CaseIterable, CustomTestStringConvertible {
        case folderNameEditor
        case folderTitle
        case searchField

        /// The layer that shows the text, the text layer inside it, and how the springboard changes the text.
        func makeLayers() -> (layer: CALayer, textLayer: CATextLayer, changeText: (String) -> Void) {
            switch self {
            case .folderNameEditor:
                let editorLayer = SpringboardTitleEditorLayer()
                editorLayer.configure(scale: 2)
                return (editorLayer, editorLayer.textLayer, { editorLayer.show(SpringboardTextEditing(selectingAllOf: $0)) })
            case .folderTitle:
                let labelLayer = SpringboardLabelLayer(font: SpringboardTypography.folderTitleFont)
                return (labelLayer, labelLayer.textLayer, { labelLayer.setString($0, contentsScale: 2) })
            case .searchField:
                let searchFieldLayer = SpringboardSearchFieldLayer()
                searchFieldLayer.configure(scale: 2)
                return (searchFieldLayer, searchFieldLayer.textLayer, searchFieldLayer.setText)
            }
        }

        var testDescription: String {
            switch self {
            case .folderNameEditor: "the folder name being typed"
            case .folderTitle: "a folder's title"
            case .searchField: "the search field"
            }
        }
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

    @Test("new text shows at once, without Core Animation's cross-fade", arguments: ChangingText.allCases)
    func newTextShowsAtOnce(_ changingText: ChangingText) throws {
        // Each key typed into a folder's name used to fade the old string out and the new one in over a
        // quarter of a second; centred, the whole name showed twice, half a character apart.
        let (layer, textLayer, changeText) = changingText.makeLayers()
        layer.frame = CGRect(x: 0, y: 0, width: 400, height: 40)
        changeText("Utilities")
        let renderer = try Self.makeRenderer(committing: layer)

        withExtendedLifetime(renderer) {
            changeText("Utilities 2")
            CATransaction.flush()
        }

        let textAnimationKeys = textLayer.animationKeys() ?? []
        #expect(textAnimationKeys.isEmpty, "The text layer animates \(textAnimationKeys)")
    }
}
