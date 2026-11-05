import CoreGraphics
import Foundation
import MachO
import ObjectiveC
import OSLog

/// The Dock's `DockBar`, which nothing exported leads to.
///
/// macOS 15's Launchpad compared each click with `-[DockBar rect]` (global coordinates, top-left
/// origin, the same space as `CGEvent.location`) to leave clicks on the Dock to the Dock.
@MainActor
enum DockBarReference {
    private static let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockBarReference")

    /// The Dock builds whose `DockBar` global this prototype knows, keyed by the arm64e slice's UUID.
    /// Dock 2571.1.32.402 (macOS 27.2, 26B123): the global the Dock's own code loads `DockBar` from,
    /// for example in `-[DockBarSystemDefinedEventHandler handleSystemDefinedEvent:type:]`.
    private static let dockBarGlobalAddressesByExecutableUUID: [UUID: UInt] = [
        UUID(uuidString: "C53975B1-2956-3ED4-B699-D4CE2E6A602C")!: 0x1_0032_9BA8,
    ]

    private(set) static weak var dockBar: AnyObject?

    static func remember(dockBar observedDockBar: AnyObject) {
        dockBar = observedDockBar
    }

    /// The bar's current rectangle, asked of the Dock; nil when the `DockBar` cannot be found.
    static var currentBarRect: CGRect? {
        guard let resolvedDockBar = (dockBar ?? readDockBarGlobal()) as? NSObject else { return nil }
        dockBar = resolvedDockBar
        typealias RectFunction = @convention(c) (AnyObject, Selector) -> CGRect
        let selector = NSSelectorFromString("rect")
        let implementation = unsafeBitCast(resolvedDockBar.method(for: selector), to: RectFunction.self)
        return implementation(resolvedDockBar, selector)
    }

    /// Reads the `DockBar` global of a Dock build listed above. Refuses anything else: on an unknown
    /// build the address means nothing, and what is read must turn out to be a `DockBar`.
    private static func readDockBarGlobal() -> AnyObject? {
        guard let executableHeader = _dyld_get_image_header(0) else { return nil }
        guard
            let executableUUID = uuid(ofImageWithHeader: executableHeader),
            let unslidGlobalAddress = dockBarGlobalAddressesByExecutableUUID[executableUUID]
        else {
            logger.error("Unknown Dock build; not reading the DockBar global")
            return nil
        }
        let slide = _dyld_get_image_vmaddr_slide(0)
        guard
            let globalPointer = UnsafeRawPointer(bitPattern: Int(bitPattern: unslidGlobalAddress) + slide),
            let objectPointer = globalPointer.load(as: UnsafeRawPointer?.self)
        else { return nil }
        let object = Unmanaged<AnyObject>.fromOpaque(objectPointer).takeUnretainedValue()
        guard String(cString: object_getClassName(object)) == "DockBar" else {
            logger.error("The DockBar global holds something else; ignoring it")
            return nil
        }
        logger.info("Found DockBar through its global")
        return object
    }

    private static func uuid(ofImageWithHeader header: UnsafePointer<mach_header>) -> UUID? {
        let headerAddress = UnsafeRawPointer(header)
        let commandCount = headerAddress.loadUnaligned(as: mach_header_64.self).ncmds
        var commandAddress = headerAddress.advanced(by: MemoryLayout<mach_header_64>.size)
        for _ in 0..<commandCount {
            let loadCommand = commandAddress.loadUnaligned(as: load_command.self)
            if loadCommand.cmd == UInt32(LC_UUID) {
                return UUID(uuid: commandAddress.loadUnaligned(as: uuid_command.self).uuid)
            }
            commandAddress = commandAddress.advanced(by: Int(loadCommand.cmdsize))
        }
        return nil
    }
}
