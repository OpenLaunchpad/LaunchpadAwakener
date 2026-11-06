import CoreGraphics
@testable import LaunchpadAwakenerPayloadCore
import QuartzCore
import Testing

/// The springboard's own layers, built without the Dock: its layer classes are missing here, so the pages
/// stay empty and the background is the stand-in blur, but the geometry is the springboard's own.
@Suite("Springboard layers")
@MainActor
struct SpringboardInterfaceTests {
    private static let screenSize = CGSize(width: 1470, height: 956)

    private static func makeInterface(rootLayer: CALayer) -> SpringboardInterface {
        let metrics = SpringboardMetrics(
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
        return SpringboardInterface(layout: .empty, metrics: metrics, scale: 2, rootLayer: rootLayer, applyEdit: { _ in })
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
}
