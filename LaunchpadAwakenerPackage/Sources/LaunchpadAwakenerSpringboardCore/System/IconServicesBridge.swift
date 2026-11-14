import CoreGraphics
import Foundation
import LaunchpadAwakenerPrivateInterfaces

/// Application icons from IconServices, the way the Dock gets its own tile images.
///
/// The Dock goes from an `LSBinding` (`-[ISIcon initWithBinding:]`); this goes from the bundle URL
/// with `-[ISIcon initWithURL:]`, which needs no private C function. IconServices exports these classes,
/// so they are declared in `LaunchpadAwakenerPrivateInterfaces` and called directly.
package enum IconServicesBridge {
    /// A descriptor for `pointSize` at `scale`: a copy of `template` — the Dock's, which carries the
    /// icon style — or a plain `ISImageDescriptor`.
    package static func makeDescriptor(copying template: NSObject?, pointSize: CGFloat, scale: CGFloat) -> NSObject? {
        let descriptor = (template?.copy() as? ISImageDescriptor) ?? ISImageDescriptor()
        descriptor.size = CGSize(width: pointSize, height: pointSize)
        descriptor.scale = Double(scale)
        return descriptor
    }

    /// The icon of the file or bundle at `fileURL`, rendered for `descriptor`. Blocks while
    /// IconServices renders, so call it off the main thread.
    package static func makeIconImage(forFileAt fileURL: URL, descriptor: NSObject) -> CGImage? {
        guard let descriptor = descriptor as? ISImageDescriptor, let icon = ISIcon(url: fileURL) else { return nil }
        icon.prepareImages(forImageDescriptors: [descriptor])
        return icon.image(forImageDescriptor: descriptor)?.cgImage
    }
}
