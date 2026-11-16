import CoreGraphics
import Darwin
import Foundation
import OSToolbox

/// Private window-server functions, called inside the Dock and from the standalone app.
///
/// Resolved at run time with `dlsym` rather than linked: the Dock already has SkyLight loaded, and the
/// payload stays free of a link-time dependency on a private framework.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "SkyLightBridge")
package enum SkyLightBridge {
    private typealias MainConnectionIdentifierFunction = @convention(c) () -> UInt32
    private typealias SetWindowLevelFunction = @convention(c) (UInt32, UInt32, Int32) -> Int32
    private typealias StealKeyFocusFunction = @convention(c) (UInt32, UInt32) -> Int32
    private typealias ReleaseKeyFocusFunction = @convention(c) (UInt32) -> Int32
    /// `SLSGetDockRectWithOrientation(connection, &rectangle, &reason, &orientation)`: returns nothing, writes all
    /// three without checking for null (27.2 `0x182A217AC`).
    private typealias GetDockRectangleFunction = @convention(c) (UInt32, UnsafeMutablePointer<CGRect>, UnsafeMutablePointer<UInt32>, UnsafeMutablePointer<UInt32>) -> Void
    /// `CGSSetWindowTags` and `CGSClearWindowTags(connection, window, &tags, 64)`: the tags are a bit set the
    /// width of the last argument, which is how the Dock itself calls them (27.2
    /// `-[DOCKWindowTile beginMinMax:minimizing:animate:]`, `0x1000339D0`).
    private typealias WindowTagsFunction = @convention(c) (UInt32, UInt32, UnsafePointer<UInt64>, Int32) -> Int32
    private static let windowTagsBitCount: Int32 = 64

    /// The flags macOS 15's `-[Springboard prepareForEnterAnimation]` passed when taking key focus.
    private static let launchpadKeyFocusFlags: UInt32 = 1152

    /// The window tag with which the window server routes no pointer events — and no drops — to a window, so they
    /// reach whatever lies below it. `-[NSWindow setIgnoresMouseEvents:]` switches between this one and
    /// ``takesPointerEventsWindowTag``, setting one and clearing the other (AppKit 27.2 `_NSSetIgnoresMouseEvents`).
    package static let ignoresPointerEventsWindowTag: UInt64 = 1 << 9
    /// The window tag with which a window takes pointer events; the springboard's window in the Dock is created
    /// with it, as macOS 15's Launchpad window was.
    package static let takesPointerEventsWindowTag: UInt64 = 1 << 10

    /// `RTLD_DEFAULT`, which Swift does not import because the C macro is a pointer cast.
    private static var defaultSymbolSearchHandle: UnsafeMutableRawPointer? {
        UnsafeMutableRawPointer(bitPattern: -2)
    }

    /// The window-server connection of the current process — inside the Dock, the Dock's own one.
    package static var mainConnectionIdentifier: UInt32? {
        resolveFunction(named: "CGSMainConnectionID", as: MainConnectionIdentifierFunction.self)
            .map { mainConnectionIdentifierFunction in mainConnectionIdentifierFunction() }
    }

    /// Moves a window owned by `connectionIdentifier` to `level`. Returns the window-server error code.
    @discardableResult
    package static func setWindowLevel(
        _ level: Int32,
        ofWindowWithIdentifier windowIdentifier: UInt32,
        onConnection connectionIdentifier: UInt32
    ) -> Int32? {
        resolveFunction(named: "CGSSetWindowLevel", as: SetWindowLevelFunction.self)
            .map { setWindowLevelFunction in setWindowLevelFunction(connectionIdentifier, windowIdentifier, level) }
    }

    /// Sends keyboard events to `connectionIdentifier` without activating an application, the way
    /// macOS 15's Launchpad did. Every successful call must be balanced by ``releaseKeyFocus(onConnection:)``.
    @discardableResult
    package static func stealKeyFocus(onConnection connectionIdentifier: UInt32) -> Int32? {
        resolveFunction(named: "CPSStealKeyFocusOnConnection", as: StealKeyFocusFunction.self)
            .map { stealKeyFocusFunction in stealKeyFocusFunction(connectionIdentifier, launchpadKeyFocusFlags) }
    }

    @discardableResult
    package static func releaseKeyFocus(onConnection connectionIdentifier: UInt32) -> Int32? {
        resolveFunction(named: "CPSReleaseKeyFocusOnConnection", as: ReleaseKeyFocusFunction.self)
            .map { releaseKeyFocusFunction in releaseKeyFocusFunction(connectionIdentifier) }
    }

    /// Lets pointer events and drops through a window owned by `connectionIdentifier` to whatever lies below it,
    /// or makes it take them again, the way `-[NSWindow setIgnoresMouseEvents:]` does. Returns the first nonzero
    /// window-server error code of setting the one tag and clearing the other, zero when both succeeded, and nil
    /// when either function is missing.
    @discardableResult
    package static func setIgnoresPointerEvents(
        _ ignoresPointerEvents: Bool,
        ofWindowWithIdentifier windowIdentifier: UInt32,
        onConnection connectionIdentifier: UInt32
    ) -> Int32? {
        guard
            let setWindowTags = resolveFunction(named: "CGSSetWindowTags", as: WindowTagsFunction.self),
            let clearWindowTags = resolveFunction(named: "CGSClearWindowTags", as: WindowTagsFunction.self)
        else { return nil }
        // The new tag goes on before the old one comes off, so the window is never left taking neither.
        var addedTags = ignoresPointerEvents ? ignoresPointerEventsWindowTag : takesPointerEventsWindowTag
        var removedTags = ignoresPointerEvents ? takesPointerEventsWindowTag : ignoresPointerEventsWindowTag
        let setResult = setWindowTags(connectionIdentifier, windowIdentifier, &addedTags, windowTagsBitCount)
        let clearResult = clearWindowTags(connectionIdentifier, windowIdentifier, &removedTags, windowTagsBitCount)
        return setResult != 0 ? setResult : clearResult
    }

    /// The rectangle the window server keeps for the Dock — the one AppKit leaves out of a screen's visible
    /// frame — in global coordinates with a top-left origin. Any process can ask; nil when the function is
    /// missing or the window server has no rectangle.
    package static var dockRectangle: CGRect? {
        guard
            let connectionIdentifier = mainConnectionIdentifier,
            let getDockRectangle = resolveFunction(named: "SLSGetDockRectWithOrientation", as: GetDockRectangleFunction.self)
        else { return nil }
        var rectangle = CGRect.zero
        var reason: UInt32 = 0
        var orientation: UInt32 = 0
        getDockRectangle(connectionIdentifier, &rectangle, &reason, &orientation)
        guard rectangle != .zero, rectangle.minX.isFinite, rectangle.minY.isFinite, rectangle.width.isFinite, rectangle.height.isFinite else { return nil }
        return rectangle
    }

    private static func resolveFunction<FunctionType>(
        named symbolName: String,
        as functionType: FunctionType.Type
    ) -> FunctionType? {
        guard let symbolAddress = dlsym(defaultSymbolSearchHandle, symbolName) else {
            #log(.error, "Could not resolve \(symbolName, privacy: .public)")
            return nil
        }
        return unsafeBitCast(symbolAddress, to: functionType)
    }
}
