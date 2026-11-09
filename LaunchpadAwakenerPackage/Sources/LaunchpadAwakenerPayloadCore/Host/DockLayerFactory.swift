import CoreGraphics
import Foundation
import ObjCRuntimeToolbox
import QuartzCore

/// `ECGridLayer`, a grid laid out row by row from the top left, its cells sized from its bounds.
@RuntimeClassProxy("ECGridLayer")
protocol DockGridLayer {
    /// Sizes cells from the bounds and asks the source for the item count once, right away. The source
    /// is held weakly.
    init?(layerSource: NSObject, rows: Int, columns: Int, scaleFactor: Float, layoutRTL: Bool)
    /// Not `layoutSublayers`, so Core Animation never calls it by itself.
    func layout()
}

/// `ECImageGridLayer`, the grid of a folder icon's thumbnails. Unlike `ECGridLayer` it asks for the item
/// count again after `layerSourceInvalidated:`.
@RuntimeClassProxy("ECImageGridLayer")
protocol DockImageGridLayer {
    init?(layerSource: NSObject, rows: Int, columns: Int, spacing: UInt, scaleFactor: Float, layoutRTL: Bool)
    func layout()
    /// Makes the grid ask its source for the item count and every item again, then lay out.
    func layerSourceInvalidated(_ source: AnyObject)
    /// Scrolls the thumbnails up to show the row after the last one, as 15 did while an icon was held
    /// over a folder.
    func scrollToAvailableSpace()
    func scrollToTop()
}

/// `ECShadowTextLayer`, which draws its shadow with the text rather than as a layer shadow; the layer
/// scales the shadow by 0.6 × its contents scale when drawing on a Retina display.
@RuntimeClassProxy("ECShadowTextLayer")
protocol DockShadowTextLayer {
    init?()
    /// A `CGColor`, which the Dock declares as an object.
    func setTextShadowColor(_ color: AnyObject)
    func setTextShadowOffset(_ offset: CGSize)
    func setTextShadowBlur(_ blur: CGFloat)
}

/// `ECTextLayer`, the Dock's text layer without a drawn shadow.
@RuntimeClassProxy("ECTextLayer")
protocol DockTextLayer {
    init?()
}

/// The Dock's category on `CALayer` that 15's selection highlight used (`setMaterialControl:3 appearance:1`).
@RuntimeClassProxy("CALayer")
protocol DockLayerMaterial {
    /// Sets the colour and compositing filter of a control material.
    func setMaterialControl(_ materialControl: UInt, appearance: UInt)
}

/// The Dock's own layer classes, used as macOS 15's Launchpad used them.
///
/// Every signature here is in ``DockHostInterface/requiredMethods``, so by the time any of this runs
/// the Dock has been checked to match.
enum DockLayerFactory {
    // MARK: - Signatures

    static let requiredMethods: [DockMethodSignature] =
        DockMethodSignature.signatures(
            ofClassNamed: DockGridLayerImplementation.runtimeClassName,
            requirements: DockGridLayerImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockImageGridLayerImplementation.runtimeClassName,
            requirements: DockImageGridLayerImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockShadowTextLayerImplementation.runtimeClassName,
            requirements: DockShadowTextLayerImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockTextLayerImplementation.runtimeClassName,
            requirements: DockTextLayerImplementation.methodRequirements
        )
        + DockMethodSignature.signatures(
            ofClassNamed: DockLayerMaterialImplementation.runtimeClassName,
            requirements: DockLayerMaterialImplementation.methodRequirements
        )

    // MARK: - ECGridLayer

    /// A grid laid out row by row from the top left, its cells sized from its bounds. `source` must
    /// answer `numberOfItemsForLayer:`, `makeLayerForLayer:` and
    /// `setContentInLayers:withDataRange:forLayer:usingScaleFactor:`, and must outlive the grid.
    static func makeGridLayer(source: NSObject, rowCount: Int, columnCount: Int, scaleFactor: Float) -> CALayer? {
        DockGridLayerImplementation(
            layerSource: source,
            rows: rowCount,
            columns: columnCount,
            scaleFactor: scaleFactor,
            layoutRTL: false
        )?.host as? CALayer
    }

    static func layoutGridLayer(_ gridLayer: CALayer) {
        DockGridLayerImplementation(gridLayer)?.layout()
    }

    // MARK: - ECImageGridLayer

    static func makeImageGridLayer(source: NSObject, rowCount: Int, columnCount: Int, spacing: UInt, scaleFactor: Float) -> CALayer? {
        DockImageGridLayerImplementation(
            layerSource: source,
            rows: rowCount,
            columns: columnCount,
            spacing: spacing,
            scaleFactor: scaleFactor,
            layoutRTL: false
        )?.host as? CALayer
    }

    static func layoutImageGridLayer(_ gridLayer: CALayer) {
        DockImageGridLayerImplementation(gridLayer)?.layout()
    }

    /// Makes the grid ask its source for the item count and every item again, then lay out.
    static func invalidateImageGridLayer(_ gridLayer: CALayer, source: NSObject) {
        DockImageGridLayerImplementation(gridLayer)?.layerSourceInvalidated(source)
    }

    /// Scrolls the grid's items so the slot after the last item shows (`toAvailableSpace`), or back to
    /// the top; animated if the current transaction animates.
    static func scrollImageGridLayer(_ gridLayer: CALayer, toAvailableSpace: Bool) {
        guard let imageGridLayer = DockImageGridLayerImplementation(gridLayer) else { return }
        if toAvailableSpace {
            imageGridLayer.scrollToAvailableSpace()
        } else {
            imageGridLayer.scrollToTop()
        }
    }

    // MARK: - ECTextLayer and ECShadowTextLayer

    /// A Dock text layer; `ECShadowTextLayer` draws its shadow with the text rather than as a layer
    /// shadow. Falls back to a plain `CATextLayer` only if the class is missing.
    static func makeTextLayer(withShadow: Bool) -> CATextLayer {
        let textLayer = withShadow ? DockShadowTextLayerImplementation()?.host : DockTextLayerImplementation()?.host
        return textLayer as? CATextLayer ?? CATextLayer()
    }

    /// The text shadow of an `ECShadowTextLayer`, in points; does nothing to any other text layer.
    static func setTextShadow(of shadowTextLayer: CATextLayer, color: CGColor, offset: CGSize, blur: CGFloat) {
        guard let dockShadowTextLayer = DockShadowTextLayerImplementation(shadowTextLayer) else { return }
        dockShadowTextLayer.setTextShadowColor(color)
        dockShadowTextLayer.setTextShadowOffset(offset)
        dockShadowTextLayer.setTextShadowBlur(blur)
    }

    // MARK: - Materials

    /// The Dock's `-[CALayer setMaterialControl:appearance:]`: sets the colour and compositing filter
    /// of a control material, as 15's selection highlight did with control 3, appearance 1.
    static func setMaterialControl(_ materialControl: UInt, appearance: UInt, of layer: CALayer) {
        DockLayerMaterialImplementation(layer)?.setMaterialControl(materialControl, appearance: appearance)
    }
}
