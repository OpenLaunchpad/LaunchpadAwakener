import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// The layers that stand in for the Dock's `EC*` classes outside the Dock. The expected values come from
/// the Dock itself — its `ECGridLayer` as the 27.2 Dock's off-screen self-check logged it — and from the
/// reverse-engineered rules in `/Volumes/RE/Dock/27.2/Notes/ECLayerReuse.md` section 5.
@MainActor
@Suite("Replica layers")
struct SpringboardReplicaLayerTests {
    private let factory = ReplicaSpringboardLayerFactory()

    /// A page of `count` empty items; the source is returned too, since the grid holds it weakly.
    private func makePageGrid(itemCount: Int, size: CGSize) throws -> (gridLayer: CALayer, source: SpringboardGridSource) {
        let metrics = SpringboardMetrics(SpringboardMetrics.Input(
            screenSize: CGSize(width: 1739, height: 1080),
            dockOrientation: .bottom,
            dockThickness: 79,
            notchHeight: 0,
            rowCount: 5,
            columnCount: 7,
            zoomStyle: 0,
            labelLineHeight: 17
        ))
        let items = (0..<itemCount).map { index in
            LaunchpadItem.application(LaunchpadApplication(
                identifier: LaunchpadItemIdentifier(rowIdentifier: Int64(index + 1)),
                title: "Application \(index)",
                bundleIdentifier: "com.example.application\(index)",
                bookmarkData: nil,
                legacyIconPNGData: nil,
                bundleURL: nil
            ))
        }
        let source = SpringboardGridSource(items: items, metrics: metrics, scale: 2)
        let gridLayer = try #require(factory.makePageGridLayer(source: source, rowCount: 5, columnCount: 7, scaleFactor: 2))
        gridLayer.frame = CGRect(origin: .zero, size: size)
        factory.layoutPageGridLayer(gridLayer)
        return (gridLayer, source)
    }

    @Test("a page lays its items out as the Dock's ECGridLayer did on a 1739 × 1080 screen")
    func pageGridMatchesTheDock() throws {
        let (_, source) = try makePageGrid(itemCount: 27, size: CGSize(width: 1351, height: 857))
        let itemLayers = source.itemLayers
        try #require(itemLayers.count == 27)
        // The 27.2 Dock's self-check: first cell {{0, 686}, {193, 171}}, last cell {{965, 173}, {193, 171}}.
        #expect(itemLayers[0].frame == CGRect(x: 0, y: 686, width: 193, height: 171))
        #expect(itemLayers[26].frame == CGRect(x: 965, y: 173, width: 193, height: 171))
    }

    @Test("the first item of a page is drawn on top of the others")
    func firstItemIsOnTop() throws {
        let (gridLayer, source) = try makePageGrid(itemCount: 3, size: CGSize(width: 1351, height: 857))
        let itemsLayer = try #require(gridLayer.sublayers?.first?.sublayers?.first)
        #expect(itemsLayer.sublayers?.last === source.itemLayers.first)
    }

    @Test("a page grid clips in its only sublayer, which the springboard can turn off as 15 did")
    func pageGridClipsInItsOnlySublayer() throws {
        let (gridLayer, _) = try makePageGrid(itemCount: 1, size: CGSize(width: 1351, height: 857))
        #expect(gridLayer.sublayers?.count == 1)
        #expect(gridLayer.sublayers?.first?.masksToBounds == true)
        #expect(gridLayer.masksToBounds == false)
    }

    // MARK: - Folder thumbnails

    /// A 3 × 3 thumbnail grid with spacing 4, laid out in a 60-point square.
    private func makeThumbnailGrid(thumbnailCount: Int) throws -> (gridLayer: CALayer, source: SpringboardThumbnailSource) {
        let source = SpringboardThumbnailSource()
        source.images = Array(repeating: nil, count: thumbnailCount)
        let gridLayer = try #require(factory.makeThumbnailGridLayer(source: source, rowCount: 3, columnCount: 3, spacing: 4, scaleFactor: 2))
        gridLayer.frame = CGRect(x: 0, y: 0, width: 60, height: 60)
        factory.layoutThumbnailGridLayer(gridLayer)
        return (gridLayer, source)
    }

    @Test("a folder's thumbnails sit in cells a third of the grid apart, each the cell less the spacing")
    func thumbnailFrames() throws {
        let (gridLayer, _) = try makeThumbnailGrid(thumbnailCount: 9)
        let itemsLayer = try #require(gridLayer.sublayers?.first)
        let thumbnailLayers = try #require(itemsLayer.sublayers)
        try #require(thumbnailLayers.count == 9)
        // Inserted at the bottom one by one, so the first thumbnail is the last sublayer.
        let firstThumbnailLayer = try #require(thumbnailLayers.last)
        let lastThumbnailLayer = try #require(thumbnailLayers.first)
        // 15.5's `_layoutItemLayers`: (2 + column × 20, 60 + 2 − (row + 1) × 20, 16, 16) in the grid.
        #expect(itemsLayer.convert(firstThumbnailLayer.frame, to: gridLayer) == CGRect(x: 2, y: 42, width: 16, height: 16))
        #expect(itemsLayer.convert(lastThumbnailLayer.frame, to: gridLayer) == CGRect(x: 42, y: 2, width: 16, height: 16))
    }

    @Test("a folder grid makes a thumbnail for every application, not only the nine it shows")
    func thumbnailCountIsNotCapped() throws {
        let (gridLayer, _) = try makeThumbnailGrid(thumbnailCount: 12)
        #expect(gridLayer.sublayers?.first?.sublayers?.count == 12)
    }

    @Test(
        "held over a folder, its thumbnails scroll to show the slot after the last application",
        arguments: [(8, 0.0), (9, -20.0), (11, -20.0), (12, -40.0)]
    )
    func thumbnailsScrollToTheAvailableSpace(thumbnailCount: Int, expectedOffset: Double) throws {
        let (gridLayer, _) = try makeThumbnailGrid(thumbnailCount: thumbnailCount)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        factory.scrollThumbnailGridLayer(gridLayer, toAvailableSpace: true)
        CATransaction.commit()
        let itemsLayer = try #require(gridLayer.sublayers?.first)
        #expect(Double(itemsLayer.bounds.origin.y) == expectedOffset)
    }

    @Test("a folder grid asks again how many thumbnails there are once told its content changed")
    func thumbnailGridTakesANewCount() throws {
        let (gridLayer, source) = try makeThumbnailGrid(thumbnailCount: 2)
        source.images = Array(repeating: nil, count: 5)
        factory.invalidateThumbnailGridLayer(gridLayer, source: source)
        #expect(gridLayer.sublayers?.first?.sublayers?.count == 5)
    }

    // MARK: - Text and materials

    @Test("a title's shadow moves 0.6 of a point per point on a Retina display, a whole one otherwise", arguments: [(2.0, 1.2), (1.0, 1.0)])
    func shadowScale(contentsScale: Double, expectedScale: Double) {
        #expect(abs(SpringboardReplicaShadowTextLayer.shadowScale(forContentsScale: contentsScale) - expectedScale) < 0.000_001)
    }

    @Test("the shadow set on a title stays with it")
    func textShadowIsKept() throws {
        let textLayer = factory.makeTextLayer(withShadow: true)
        factory.setTextShadow(of: textLayer, color: CGColor(gray: 0, alpha: 0.2), offset: CGSize(width: 0, height: -1), blur: 2)
        let shadowTextLayer = try #require(textLayer as? SpringboardReplicaShadowTextLayer)
        #expect(shadowTextLayer.textShadowOffset == CGSize(width: 0, height: -1))
        #expect(shadowTextLayer.textShadowBlur == 2)
        #expect(shadowTextLayer.textShadowColor?.alpha == 0.2)
    }

    @Test("15's selection material is sRGB grey 232/255 that darkens what lies behind it")
    func selectionMaterial() throws {
        let layer = CALayer()
        factory.applySelectionMaterial(to: layer)
        let standardRGB = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let components = try #require(layer.backgroundColor?.converted(to: standardRGB, intent: .defaultIntent, options: nil)?.components)
        #expect(components.prefix(3).allSatisfy { abs($0 - 232.0 / 255) < 0.000_001 })
        #expect(layer.compositingFilter as? String == "plusD")
    }
}
