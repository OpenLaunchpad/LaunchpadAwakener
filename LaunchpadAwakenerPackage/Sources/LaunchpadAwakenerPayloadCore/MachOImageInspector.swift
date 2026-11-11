import Foundation
import MachO

/// Reads load commands of an image that dyld has already mapped.
enum MachOImageInspector {
    /// The image's `LC_UUID`, or nil when it has none.
    static func uuid(ofImageWithHeader header: UnsafePointer<mach_header>) -> UUID? {
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
