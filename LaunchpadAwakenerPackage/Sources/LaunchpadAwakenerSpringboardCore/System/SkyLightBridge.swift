import Darwin
import Foundation
import OSToolbox

/// Private window-server functions the payload calls inside the Dock.
///
/// Resolved at run time with `dlsym` rather than linked: the Dock already has SkyLight loaded, and the
/// payload stays free of a link-time dependency on a private framework.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "SkyLightBridge")
package enum SkyLightBridge {
    private typealias MainConnectionIdentifierFunction = @convention(c) () -> UInt32
    private typealias SetWindowLevelFunction = @convention(c) (UInt32, UInt32, Int32) -> Int32
    private typealias StealKeyFocusFunction = @convention(c) (UInt32, UInt32) -> Int32
    private typealias ReleaseKeyFocusFunction = @convention(c) (UInt32) -> Int32

    /// The flags macOS 15's `-[Springboard prepareForEnterAnimation]` passed when taking key focus.
    private static let launchpadKeyFocusFlags: UInt32 = 1152

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
