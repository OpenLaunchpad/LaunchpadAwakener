import CoreGraphics
import Foundation
import LaunchpadAwakenerHookKit
import QuartzCore

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
