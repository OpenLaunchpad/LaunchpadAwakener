import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import Metal
import QuartzCore
import Testing

/// How an icon held over another changes the target, by macOS 15.5's rules. A folder's own square grows
/// to 1.1 with the default animation, after its frame was set to the whole icon at once, and shrinks back
/// the same way (`-[ECSBGroupItemLayer setHighlighted:]`, 15.5 `0x1000771C4`); the target's title fades
/// out and back in (`-[ECSBOpenGroupDragState beginTransition]` `0x1000858D0`, `cancelTransition`
/// `0x100085C5C`). An application's square is made new each time, so it shows and goes at once
/// (`-[ECSBItemLayer setHighlighted:]` `0x1000608F8`).
@Suite("The target of an icon held over it")
@MainActor
struct SpringboardDropTargetAnimationTests {
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

    private static let folder = LaunchpadFolder(
        identifier: LaunchpadItemIdentifier(rowIdentifier: 50),
        title: "Utilities",
        pages: [LaunchpadFolderPage(identifier: LaunchpadItemIdentifier(rowIdentifier: 51), applications: [application(52, title: "Console"), application(53, title: "Grapher")])]
    )

    /// `item` laid out in a cell of its own.
    private static func makeItemLayer(for item: LaunchpadItem) -> (canvasLayer: CALayer, itemLayer: SpringboardItemLayer) {
        let canvasLayer = CALayer()
        canvasLayer.frame = CGRect(origin: .zero, size: metrics.cellSize)
        let itemLayer = SpringboardItemLayer()
        itemLayer.configure(with: item, metrics: metrics, scale: 1)
        itemLayer.frame = canvasLayer.bounds
        canvasLayer.addSublayer(itemLayer)
        itemLayer.layoutIfNeeded()
        return (canvasLayer, itemLayer)
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

    @Test("a folder held over grows its square to 1.1 of the whole icon with an animation, keeping its shape, and fades its title out")
    func folderGrows() throws {
        let (canvasLayer, itemLayer) = Self.makeItemLayer(for: .folder(Self.folder))
        let renderer = try Self.makeRenderer(committing: canvasLayer)
        let backdropLayer = try #require(itemLayer.backdropLayer)

        withExtendedLifetime(renderer) {
            itemLayer.isDropTarget = true
            CATransaction.flush()
        }

        #expect(backdropLayer.animation(forKey: "transform") != nil)
        #expect(itemLayer.labelLayer.animation(forKey: "opacity") != nil)
        // As 15.5 looked next to the replica: as large as 1.1 of the whole icon, its corners grown with it so
        // that it keeps the shape of the folder's square. Only the scale changes, so the growth is one smooth
        // animation.
        #expect(backdropLayer.animation(forKey: "bounds") == nil)
        #expect(backdropLayer.bounds.size == itemLayer.folderBackdropFrame.size)
        #expect(backdropLayer.cornerRadius == itemLayer.folderCornerRadius)
        let iconFrame = itemLayer.iconFrame
        let grownFrame = iconFrame.insetBy(dx: -iconFrame.width * 0.05, dy: -iconFrame.height * 0.05)
        #expect(abs(backdropLayer.frame.width - grownFrame.width) < 0.001)
        #expect(abs(backdropLayer.frame.height - grownFrame.height) < 0.001)
        #expect(abs(backdropLayer.frame.midX - grownFrame.midX) < 0.001)
        #expect(abs(backdropLayer.frame.midY - grownFrame.midY) < 0.001)
    }

    @Test("a folder held over keeps its square's size through a layout")
    func folderKeepsSizeThroughLayout() throws {
        let (_, itemLayer) = Self.makeItemLayer(for: .folder(Self.folder))
        let backdropLayer = try #require(itemLayer.backdropLayer)
        itemLayer.isDropTarget = true

        itemLayer.setNeedsLayout()
        itemLayer.layoutIfNeeded()

        #expect(backdropLayer.bounds.size == itemLayer.folderBackdropFrame.size)
        #expect(backdropLayer.position == CGPoint(x: itemLayer.folderBackdropFrame.midX, y: itemLayer.folderBackdropFrame.midY))
    }

    @Test("a folder no longer held over shrinks its square back with an animation, and fades its title in")
    func folderShrinksBack() throws {
        let (canvasLayer, itemLayer) = Self.makeItemLayer(for: .folder(Self.folder))
        let renderer = try Self.makeRenderer(committing: canvasLayer)
        let backdropLayer = try #require(itemLayer.backdropLayer)
        itemLayer.isDropTarget = true
        CATransaction.flush()
        backdropLayer.removeAllAnimations()
        itemLayer.labelLayer.removeAllAnimations()

        withExtendedLifetime(renderer) {
            itemLayer.isDropTarget = false
            CATransaction.flush()
        }

        #expect(backdropLayer.animation(forKey: "transform") != nil)
        #expect(itemLayer.labelLayer.animation(forKey: "opacity") != nil)
        #expect(CATransform3DIsIdentity(backdropLayer.transform))
        #expect(backdropLayer.frame == itemLayer.folderBackdropFrame)
    }

    @Test("an application held over shows its square at once, as 15's new layers did, and fades its title out")
    func applicationSquareShowsAtOnce() throws {
        let (canvasLayer, itemLayer) = Self.makeItemLayer(for: .application(Self.application(10, title: "Calculator")))
        let renderer = try Self.makeRenderer(committing: canvasLayer)

        withExtendedLifetime(renderer) {
            itemLayer.isDropTarget = true
            CATransaction.flush()
        }

        let backdropLayer = try #require(itemLayer.backdropLayer)
        #expect(backdropLayer.animation(forKey: "transform") == nil)
        #expect(itemLayer.labelLayer.animation(forKey: "opacity") != nil)
    }
}
