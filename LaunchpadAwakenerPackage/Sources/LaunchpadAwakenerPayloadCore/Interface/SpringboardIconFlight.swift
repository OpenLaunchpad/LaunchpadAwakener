import CoreGraphics
import Foundation
import QuartzCore

/// An icon's image shrinking into a folder icon's thumbnail, as macOS 15 made a folder or dropped an
/// icon into one (`-[ECSBOpenGroupDragState _minimizeLayer:toGroupItemLayer:atMiniImageLayer:]`,
/// 15.5 `0x10008483C`).
///
/// The image ends 3 points narrower than the thumbnail, centred 1 point left of and 1 point above the
/// thumbnail's centre, its shadow fading in; the default animation carries it there. The thumbnail,
/// hidden until then, fades in beneath it over the same time, and then the image goes: 0.5 s in all.
/// The image rides above everything in the folder icon.
@MainActor
enum SpringboardIconFlight {
    static let duration: CFTimeInterval = 0.25

    /// A copy of `imageLayer`'s image where it is now, in `destinationLayer`'s coordinates. Add it to
    /// `destinationLayer`, then commit it — `CATransaction.flush()` — before it flies.
    static func makeFlyingLayer(copying imageLayer: CALayer, in destinationLayer: CALayer) -> CALayer {
        let flyingLayer = CALayer()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        flyingLayer.contents = imageLayer.contents
        flyingLayer.contentsGravity = imageLayer.contentsGravity
        flyingLayer.contentsScale = imageLayer.contentsScale
        flyingLayer.compositingFilter = imageLayer.compositingFilter
        flyingLayer.frame = imageLayer.convert(imageLayer.bounds, to: destinationLayer)
        CATransaction.commit()
        return flyingLayer
    }

    /// Flies `flyingLayer`, a sublayer of `folderItemLayer`, into the thumbnail of `slot`; fades that
    /// thumbnail in beneath it, removes it, then calls `completion`.
    static func fly(
        _ flyingLayer: CALayer,
        intoThumbnailAt slot: Int,
        of folderItemLayer: SpringboardItemLayer,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard let thumbnailRect = folderItemLayer.thumbnailFrame(atSlot: slot), flyingLayer.bounds.width > 0 else {
            flyingLayer.removeFromSuperlayer()
            folderItemLayer.setThumbnailOpacity(1, forSlots: slot..<(slot + 1))
            completion?()
            return
        }
        let scale = max(thumbnailRect.width - 3, 1) / flyingLayer.bounds.width
        CATransaction.begin()
        CATransaction.setAnimationDuration(duration)
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated {
                CATransaction.begin()
                CATransaction.setAnimationDuration(duration)
                CATransaction.setCompletionBlock {
                    MainActor.assumeIsolated {
                        CATransaction.begin()
                        CATransaction.setDisableActions(true)
                        flyingLayer.removeFromSuperlayer()
                        CATransaction.commit()
                        completion?()
                    }
                }
                folderItemLayer.setThumbnailOpacity(1, forSlots: slot..<(slot + 1))
                CATransaction.commit()
            }
        }
        flyingLayer.position = CGPoint(x: thumbnailRect.midX - 1, y: thumbnailRect.midY + 1)
        flyingLayer.transform = CATransform3DMakeScale(scale, scale, 1)
        // A layer's shadow is already 3 points down and 3 points soft; only its opacity changes.
        flyingLayer.shadowOffset = CGSize(width: 0, height: -3)
        flyingLayer.shadowRadius = 3
        flyingLayer.shadowOpacity = 1
        CATransaction.commit()
    }
}
