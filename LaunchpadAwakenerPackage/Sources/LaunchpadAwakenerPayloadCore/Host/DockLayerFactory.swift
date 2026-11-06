import CoreGraphics
import Foundation
import LaunchpadAwakenerHookKit
import ObjectiveC
import QuartzCore

/// The Dock's own layer classes, used as macOS 15's Launchpad used them.
///
/// Every signature here is in ``DockHostInterface/requiredMethods``, so by the time any of this runs
/// the Dock has been checked to match; the calls themselves do not check again.
enum DockLayerFactory {
    // MARK: - Signatures

    /// `-[ECGridLayer initWithLayerSource:rows:columns:scaleFactor:layoutRTL:]`: sizes cells from its
    /// bounds and asks the source for the item count once, right away. The source is held weakly.
    static let gridLayerInitialiser = DockMethodSignature(
        className: "ECGridLayer",
        selectorName: "initWithLayerSource:rows:columns:scaleFactor:layoutRTL:",
        typeEncoding: "@48@0:8@16q24q32f40B44"
    )
    /// `-[ECGridLayer layout]`: not `layoutSublayers`, so Core Animation never calls it by itself.
    static let gridLayerLayout = DockMethodSignature(className: "ECGridLayer", selectorName: "layout", typeEncoding: "v16@0:8")
    static let shadowTextLayerInitialiser = DockMethodSignature(className: "ECShadowTextLayer", selectorName: "init", typeEncoding: "@16@0:8")
    static let shadowTextLayerShadowColor = DockMethodSignature(className: "ECShadowTextLayer", selectorName: "setTextShadowColor:", typeEncoding: "v24@0:8@16")
    static let shadowTextLayerShadowOffset = DockMethodSignature(className: "ECShadowTextLayer", selectorName: "setTextShadowOffset:", typeEncoding: "v32@0:8{CGSize=dd}16")
    static let shadowTextLayerShadowBlur = DockMethodSignature(className: "ECShadowTextLayer", selectorName: "setTextShadowBlur:", typeEncoding: "v24@0:8d16")
    static let textLayerInitialiser = DockMethodSignature(className: "ECTextLayer", selectorName: "init", typeEncoding: "@16@0:8")
    /// `-[ECImageGridLayer initWithLayerSource:rows:columns:spacing:scaleFactor:layoutRTL:]`: the grid
    /// of a folder icon's thumbnails. Unlike `ECGridLayer` it asks for the item count again after
    /// `layerSourceInvalidated:`.
    static let imageGridLayerInitialiser = DockMethodSignature(
        className: "ECImageGridLayer",
        selectorName: "initWithLayerSource:rows:columns:spacing:scaleFactor:layoutRTL:",
        typeEncoding: "@56@0:8@16q24q32Q40f48B52"
    )
    static let imageGridLayerLayout = DockMethodSignature(className: "ECImageGridLayer", selectorName: "layout", typeEncoding: "v16@0:8")
    static let imageGridLayerInvalidate = DockMethodSignature(className: "ECImageGridLayer", selectorName: "layerSourceInvalidated:", typeEncoding: "v24@0:8@16")
    /// Scrolls the thumbnails up to show the row after the last one, as 15 did while an icon was held
    /// over a folder; `scrollToTop` scrolls back.
    static let imageGridLayerScrollToAvailableSpace = DockMethodSignature(className: "ECImageGridLayer", selectorName: "scrollToAvailableSpace", typeEncoding: "v16@0:8")
    static let imageGridLayerScrollToTop = DockMethodSignature(className: "ECImageGridLayer", selectorName: "scrollToTop", typeEncoding: "v16@0:8")
    /// The Dock's category on `CALayer` that 15's selection highlight used (`setMaterialControl:3 appearance:1`).
    static let layerMaterialControl = DockMethodSignature(className: "CALayer", selectorName: "setMaterialControl:appearance:", typeEncoding: "v32@0:8Q16Q24")

    static let requiredMethods: [DockMethodSignature] = [
        gridLayerInitialiser,
        gridLayerLayout,
        shadowTextLayerInitialiser,
        shadowTextLayerShadowColor,
        shadowTextLayerShadowOffset,
        shadowTextLayerShadowBlur,
        textLayerInitialiser,
        layerMaterialControl,
        imageGridLayerInitialiser,
        imageGridLayerLayout,
        imageGridLayerInvalidate,
        imageGridLayerScrollToAvailableSpace,
        imageGridLayerScrollToTop,
    ]

    // MARK: - ECGridLayer

    /// A grid laid out row by row from the top left, its cells sized from its bounds. `source` must
    /// answer `numberOfItemsForLayer:`, `makeLayerForLayer:` and
    /// `setContentInLayers:withDataRange:forLayer:usingScaleFactor:`, and must outlive the grid.
    static func makeGridLayer(source: NSObject, rowCount: Int, columnCount: Int, scaleFactor: Float) -> CALayer? {
        typealias InitialiserFunction = @convention(c) (AnyObject, Selector, AnyObject, Int, Int, Float, Bool) -> Unmanaged<CALayer>?
        let signature = gridLayerInitialiser
        guard
            let gridClass = NSClassFromString(signature.className) as? CALayer.Type,
            let initialiserImplementation = class_getMethodImplementation(gridClass, signature.selector),
            // alloc without init; the initialiser consumes this reference and returns +1.
            let allocatedGrid = gridClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { return nil }
        let initialiser = unsafeBitCast(initialiserImplementation, to: InitialiserFunction.self)
        return initialiser(allocatedGrid, signature.selector, source, rowCount, columnCount, scaleFactor, false)?.takeRetainedValue()
    }

    static func layoutGridLayer(_ gridLayer: CALayer) {
        typealias LayoutFunction = @convention(c) (AnyObject, Selector) -> Void
        let selector = gridLayerLayout.selector
        let implementation = unsafeBitCast(gridLayer.method(for: selector), to: LayoutFunction.self)
        implementation(gridLayer, selector)
    }

    // MARK: - ECImageGridLayer

    static func makeImageGridLayer(source: NSObject, rowCount: Int, columnCount: Int, spacing: UInt, scaleFactor: Float) -> CALayer? {
        typealias InitialiserFunction = @convention(c) (AnyObject, Selector, AnyObject, Int, Int, UInt, Float, Bool) -> Unmanaged<CALayer>?
        let signature = imageGridLayerInitialiser
        guard
            let gridClass = NSClassFromString(signature.className) as? CALayer.Type,
            let initialiserImplementation = class_getMethodImplementation(gridClass, signature.selector),
            // alloc without init; the initialiser consumes this reference and returns +1.
            let allocatedGrid = gridClass.perform(NSSelectorFromString("alloc"))?.takeUnretainedValue()
        else { return nil }
        let initialiser = unsafeBitCast(initialiserImplementation, to: InitialiserFunction.self)
        return initialiser(allocatedGrid, signature.selector, source, rowCount, columnCount, spacing, scaleFactor, false)?.takeRetainedValue()
    }

    static func layoutImageGridLayer(_ gridLayer: CALayer) {
        typealias LayoutFunction = @convention(c) (AnyObject, Selector) -> Void
        let selector = imageGridLayerLayout.selector
        unsafeBitCast(gridLayer.method(for: selector), to: LayoutFunction.self)(gridLayer, selector)
    }

    /// Makes the grid ask its source for the item count and every item again, then lay out.
    static func invalidateImageGridLayer(_ gridLayer: CALayer, source: NSObject) {
        typealias InvalidateFunction = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        let selector = imageGridLayerInvalidate.selector
        unsafeBitCast(gridLayer.method(for: selector), to: InvalidateFunction.self)(gridLayer, selector, source)
    }

    /// Scrolls the grid's items so the slot after the last item shows (`toAvailableSpace`), or back to
    /// the top; animated if the current transaction animates.
    static func scrollImageGridLayer(_ gridLayer: CALayer, toAvailableSpace: Bool) {
        typealias ScrollFunction = @convention(c) (AnyObject, Selector) -> Void
        let selector = toAvailableSpace ? imageGridLayerScrollToAvailableSpace.selector : imageGridLayerScrollToTop.selector
        unsafeBitCast(gridLayer.method(for: selector), to: ScrollFunction.self)(gridLayer, selector)
    }

    // MARK: - ECTextLayer and ECShadowTextLayer

    /// A Dock text layer; `ECShadowTextLayer` draws its shadow with the text rather than as a layer
    /// shadow. Falls back to a plain `CATextLayer` only if the class is missing.
    static func makeTextLayer(withShadow: Bool) -> CATextLayer {
        let className = withShadow ? shadowTextLayerInitialiser.className : textLayerInitialiser.className
        guard let textLayerClass = NSClassFromString(className) as? CATextLayer.Type else { return CATextLayer() }
        return textLayerClass.init()
    }

    /// The text shadow of an `ECShadowTextLayer`, in points; the layer scales it by 0.6 × its
    /// contents scale when drawing on a Retina display.
    static func setTextShadow(of shadowTextLayer: CATextLayer, color: CGColor, offset: CGSize, blur: CGFloat) {
        guard String(cString: object_getClassName(shadowTextLayer)) == shadowTextLayerShadowColor.className else { return }
        typealias SetColorFunction = @convention(c) (AnyObject, Selector, AnyObject) -> Void
        typealias SetOffsetFunction = @convention(c) (AnyObject, Selector, CGSize) -> Void
        typealias SetBlurFunction = @convention(c) (AnyObject, Selector, CGFloat) -> Void
        let setColor = unsafeBitCast(shadowTextLayer.method(for: shadowTextLayerShadowColor.selector), to: SetColorFunction.self)
        setColor(shadowTextLayer, shadowTextLayerShadowColor.selector, color)
        let setOffset = unsafeBitCast(shadowTextLayer.method(for: shadowTextLayerShadowOffset.selector), to: SetOffsetFunction.self)
        setOffset(shadowTextLayer, shadowTextLayerShadowOffset.selector, offset)
        let setBlur = unsafeBitCast(shadowTextLayer.method(for: shadowTextLayerShadowBlur.selector), to: SetBlurFunction.self)
        setBlur(shadowTextLayer, shadowTextLayerShadowBlur.selector, blur)
    }

    // MARK: - Materials

    /// The Dock's `-[CALayer setMaterialControl:appearance:]`: sets the colour and compositing filter
    /// of a control material, as 15's selection highlight did with control 3, appearance 1.
    static func setMaterialControl(_ materialControl: UInt, appearance: UInt, of layer: CALayer) {
        typealias SetMaterialFunction = @convention(c) (AnyObject, Selector, UInt, UInt) -> Void
        let selector = layerMaterialControl.selector
        let implementation = unsafeBitCast(layer.method(for: selector), to: SetMaterialFunction.self)
        implementation(layer, selector, materialControl, appearance)
    }
}

/// Core Animation's private filters, by the names the system exports for them.
enum QuartzCorePrivate {
    /// `RTLD_DEFAULT`, which Swift does not import because the C macro is a pointer cast.
    private static var defaultSymbolSearchHandle: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: -2)
    }

    /// The value of an exported `NSString *` constant such as `kCAFilterPlusD`.
    static func stringConstant(named symbolName: String) -> String? {
        guard let symbolAddress = dlsym(defaultSymbolSearchHandle, symbolName) else { return nil }
        guard let stringPointer = symbolAddress.load(as: UnsafeRawPointer?.self) else { return nil }
        return Unmanaged<NSString>.fromOpaque(stringPointer).takeUnretainedValue() as String
    }

    /// A `CABackdropLayer`, which filters whatever lies behind it; a plain layer if the class is gone.
    ///
    /// `isWindowServerAware` makes the window server fill it from everything behind it on screen — other
    /// windows too, and backdrops of the same window beneath it — as the Dock's own glass is filled.
    /// Without it, it sees only this window's own layers beneath it.
    static func makeBackdropLayer(isWindowServerAware: Bool = false) -> CALayer {
        let backdropLayer = (NSClassFromString("CABackdropLayer") as? CALayer.Type)?.init() ?? CALayer()
        if isWindowServerAware, backdropLayer.responds(to: NSSelectorFromString("setWindowServerAware:")) {
            backdropLayer.setValue(true, forKey: "windowServerAware")
        }
        return backdropLayer
    }

    /// Blur 30 with hard edges, then saturation 1.8: the first of 15's filters on the desktop behind
    /// Launchpad (15.5 `0x100007C48`). 15 also asked them of an open folder's backdrop (`0x10004BE70`),
    /// but as `backgroundFilters`, which a backdrop does not apply.
    static func blurAndSaturationFilters() -> [Any]? {
        guard
            let blurFilterType = stringConstant(named: "kCAFilterGaussianBlur"),
            let saturationFilterType = stringConstant(named: "kCAFilterColorSaturate"),
            let blurFilter = makeFilter(type: blurFilterType),
            let saturationFilter = makeFilter(type: saturationFilterType)
        else { return nil }
        blurFilter.setValue(30, forKey: "inputRadius")
        blurFilter.setValue(true, forKey: "inputHardEdges")
        saturationFilter.setValue(1.8, forKey: "inputAmount")
        return [blurFilter, saturationFilter]
    }

    /// What macOS 15 did to the desktop behind Launchpad: blur 30 with hard edges, saturation 1.8, then
    /// every channel at 55 % plus 5.3 % (`-[Springboard init]`, 15.5 `0x100007C48`). There is no other
    /// dimming. The wallpaper background, and the stand-in when the Dock's own glass is unavailable.
    static func desktopBackgroundFilters() -> [Any]? {
        guard
            let colorMatrixFilterType = stringConstant(named: "kCAFilterColorMatrix"),
            let colorMatrixFilter = makeFilter(type: colorMatrixFilterType),
            let blurAndSaturationFilters = Self.blurAndSaturationFilters()
        else { return nil }
        let colorMatrixEntries: [Float] = [
            0.55, 0, 0, 0, 0.05292,
            0, 0.55, 0, 0, 0.05292,
            0, 0, 0.55, 0, 0.05292,
            0, 0, 0, 1, 0,
        ]
        // `+[NSValue valueWithCAColorMatrix:]` is exactly this.
        let colorMatrixValue = colorMatrixEntries.withUnsafeBytes { entryBytes in
            NSValue(bytes: entryBytes.baseAddress!, objCType: "{CAColorMatrix=ffffffffffffffffffff}")
        }
        colorMatrixFilter.setValue(colorMatrixValue, forKey: "inputColorMatrix")
        return blurAndSaturationFilters + [colorMatrixFilter]
    }

    /// `+[CAFilter filterWithType:]`, for filters `CALayer.filters` accepts in the render server.
    static func makeFilter(type filterType: String) -> NSObject? {
        guard
            let filterClass = NSClassFromString("CAFilter") as? NSObject.Type,
            MethodHookInspector.hasMethod(
                className: "CAFilter",
                selector: NSSelectorFromString("filterWithType:"),
                matchingTypeEncoding: "@24@0:8@16",
                isInstanceMethod: false
            )
        else { return nil }
        return filterClass.perform(NSSelectorFromString("filterWithType:"), with: filterType)?.takeUnretainedValue() as? NSObject
    }
}
