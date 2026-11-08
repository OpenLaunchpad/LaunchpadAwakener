import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import Metal
import ObjectiveC
import QuartzCore
import Testing

/// How an icon's highlights blend with the wallpaper behind it.
@Suite("Highlights over the wallpaper")
@MainActor
struct SpringboardSelectionTests {
    private static let application = LaunchpadApplication(
        identifier: LaunchpadItemIdentifier(rowIdentifier: 12),
        title: "Calendar",
        bundleIdentifier: "com.example.calendar",
        bookmarkData: nil,
        legacyIconPNGData: nil,
        bundleURL: URL(fileURLWithPath: "/Applications/Calendar.app")
    )

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

    /// An application's item over a dark blue, like a blurred wallpaper, laid out in a cell of its own.
    private static func makeItemOverWallpaper() -> (canvasLayer: CALayer, itemLayer: SpringboardItemLayer) {
        let canvasLayer = CALayer()
        canvasLayer.frame = CGRect(origin: .zero, size: metrics.cellSize)
        canvasLayer.backgroundColor = CGColor(srgbRed: 0.2, green: 0.3, blue: 0.6, alpha: 1)
        let itemLayer = SpringboardItemLayer()
        itemLayer.configure(with: .application(application), metrics: metrics, scale: 1)
        itemLayer.frame = canvasLayer.bounds
        canvasLayer.addSublayer(itemLayer)
        itemLayer.layoutIfNeeded()
        return (canvasLayer, itemLayer)
    }

    @Test("the selection darkens the wallpaper behind it instead of covering it in light grey")
    func selectionDarkensWhatIsBehindIt() throws {
        // 15 drew the selection in grey 232/255 with plus-darker, which takes 23/255 off whatever lies
        // behind it. Its parent, the jitter layer, blended as a group, so the grey had nothing beneath it to
        // darken and showed as an opaque light square with the white title on it.
        DockMaterialStandIn.install()
        let (canvasLayer, itemLayer) = Self.makeItemOverWallpaper()
        itemLayer.isSelected = true

        let pixels = try RenderedPixels(of: canvasLayer)
        let background = try pixels.plainBackground(atColumn: 1)
        // Beside the icon and its title, where only the selection covers the background: 15 widened it at
        // least 7 points past both.
        let besideColumn = pixels.column(at: Int(itemLayer.iconFrame.union(itemLayer.restingLabelFrame).minX) - 3)
        let lightGreyCount = besideColumn.count(where: \.isLightGrey)
        let darkenedCount = besideColumn.count { pixel in
            pixel.red + 13 <= background.red && pixel.green + 13 <= background.green && pixel.blue + 13 <= background.blue
        }
        #expect(lightGreyCount == 0, "Light grey beside the icon, such as \(besideColumn.first(where: \.isLightGrey).map(String.init(describing:)) ?? "-"); background \(background)")
        #expect(darkenedCount > 0, "Nothing beside the icon is darker than the background \(background)")
    }

    @Test("the square behind a drop target lets the wallpaper show through")
    func dropTargetSquareIsTranslucent() throws {
        // 15 put a white square at half opacity behind the target with a darkening grey tint over it, both in
        // the jitter layer. Blended as a group, the tint turned the square opaque light grey.
        let (canvasLayer, itemLayer) = Self.makeItemOverWallpaper()
        itemLayer.isDropTarget = true

        let pixels = try RenderedPixels(of: canvasLayer)
        // Down the middle of the icon, which has no picture here, so the square shows wherever it is.
        let iconColumn = pixels.column(at: Int(itemLayer.iconFrame.midX))
        let lightGreyCount = iconColumn.count(where: \.isLightGrey)
        let frostedBlueCount = iconColumn.count { pixel in pixel.red >= 120 && pixel.blue >= pixel.red + 30 }
        #expect(lightGreyCount == 0, "Light grey in the square, such as \(iconColumn.first(where: \.isLightGrey).map(String.init(describing:)) ?? "-")")
        #expect(frostedBlueCount > 0, "The wallpaper's blue does not show through the square")
    }

    @Test("an icon's compositing filter works on the icon alone, not on the wallpaper")
    func iconCompositingStaysWithTheIcon() throws {
        // The Dock gives icons a compositing filter in the clear and tinted styles, and blends each one inside
        // its tile (`-[DOCKTileLayer init]`, 27.2 `0x10007E348`), so the icon looks the same over any
        // wallpaper. Plus-darker shows it plainly: alone, a mid-grey picture stays mid-grey.
        let (canvasLayer, itemLayer) = Self.makeItemOverWallpaper()
        let plusDarkerFilterName = try #require(QuartzCorePrivate.stringConstant(named: "kCAFilterPlusD"))
        itemLayer.setApplicationIcon(try Self.makeGreyPicture(), compositingFilterName: plusDarkerFilterName)

        let pixels = try RenderedPixels(of: canvasLayer)
        let iconColumn = pixels.column(at: Int(itemLayer.iconFrame.midX))
        let midGreyCount = iconColumn.count { pixel in
            [pixel.red, pixel.green, pixel.blue].allSatisfy { abs($0 - 128) <= 3 }
        }
        #expect(midGreyCount > 0, "The icon's grey blended with the wallpaper")
    }

    /// An opaque square of grey 128/255.
    private static func makeGreyPicture() throws -> CGImage {
        let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(
            data: nil,
            width: 32,
            height: 32,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(CGColor(srgbRed: 128.0 / 255, green: 128.0 / 255, blue: 128.0 / 255, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        return try #require(context.makeImage())
    }
}

/// The Dock's `-[CALayer setMaterialControl:appearance:]` (27.2 `0x1000A5328`, the same in 15.5), which
/// the test process does not have. Only the selection's material is stood in for: control 3 in the dark
/// appearance, grey 232/255 composited with plus-darker.
private enum DockMaterialStandIn {
    static func install() {
        let selector = NSSelectorFromString("setMaterialControl:appearance:")
        guard !CALayer.instancesRespond(to: selector) else { return }
        let plusDarkerFilterName = QuartzCorePrivate.stringConstant(named: "kCAFilterPlusD")
        let setMaterial: @convention(block) (CALayer, UInt, UInt) -> Void = { layer, materialControl, appearance in
            guard materialControl == 3, appearance == 1 else {
                Issue.record("No stand-in for material control \(materialControl) in appearance \(appearance)")
                return
            }
            layer.backgroundColor = CGColor(srgbRed: 232.0 / 255, green: 232.0 / 255, blue: 232.0 / 255, alpha: 1)
            layer.compositingFilter = plusDarkerFilterName
        }
        class_addMethod(CALayer.self, selector, imp_implementationWithBlock(setMaterial), "v32@0:8Q16Q24")
    }
}

/// A layer tree drawn off screen by Core Animation, one point to a pixel, read back.
private struct RenderedPixels {
    struct Pixel: Equatable, CustomStringConvertible {
        let red: Int
        let green: Int
        let blue: Int

        var isLightGrey: Bool {
            red >= 204 && green >= 204 && blue >= 204
        }

        var description: String {
            "(\(red), \(green), \(blue))"
        }
    }

    let width: Int
    let height: Int
    /// Blue, green, red, alpha for each pixel, row by row.
    private let bytes: [UInt8]

    @MainActor
    init(of layer: CALayer) throws {
        width = Int(layer.bounds.width)
        height = Int(layer.bounds.height)
        let device = try #require(MTLCreateSystemDefaultDevice())
        let commandQueue = try #require(device.makeCommandQueue())
        let textureDescriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
        textureDescriptor.usage = [.renderTarget, .shaderRead]
        textureDescriptor.storageMode = .shared
        let texture = try #require(device.makeTexture(descriptor: textureDescriptor))
        let renderer = CARenderer(mtlTexture: texture, options: [kCARendererMetalCommandQueue: commandQueue])
        renderer.layer = layer
        renderer.bounds = layer.bounds
        CATransaction.flush()
        renderer.beginFrame(atTime: CACurrentMediaTime(), timeStamp: nil)
        renderer.addUpdate(renderer.bounds)
        renderer.render()
        renderer.endFrame()
        // The renderer's work is on this queue; once a later command buffer completes, so has the frame.
        let completionBuffer = try #require(commandQueue.makeCommandBuffer())
        completionBuffer.commit()
        completionBuffer.waitUntilCompleted()
        var readBytes = [UInt8](repeating: 0, count: width * height * 4)
        texture.getBytes(&readBytes, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        bytes = readBytes
    }

    /// Every pixel in column `x`, top to bottom.
    func column(at x: Int) -> [Pixel] {
        (0..<height).map { row in
            let offset = (row * width + x) * 4
            return Pixel(red: Int(bytes[offset + 2]), green: Int(bytes[offset + 1]), blue: Int(bytes[offset]))
        }
    }

    /// The one colour of column `x`, which nothing covers.
    func plainBackground(atColumn x: Int) throws -> Pixel {
        let backgroundColumn = column(at: x)
        let background = try #require(backgroundColumn.first)
        try #require(backgroundColumn.allSatisfy { $0 == background }, "Column \(x) is not plain background")
        return background
    }
}
