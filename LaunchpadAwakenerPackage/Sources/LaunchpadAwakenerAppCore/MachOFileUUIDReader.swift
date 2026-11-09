import Foundation
import MachO

/// Reads the `LC_UUID` of every slice in a Mach-O file on disk.
///
/// The payload reports the UUID of the image it is running as; comparing that against the slices of
/// the payload in this app's bundle tells whether the Dock holds this build of it or an older one.
/// Each architecture is linked separately and gets its own UUID, so a universal file yields several
/// and the resident payload is current when its UUID is any one of them.
enum MachOFileUUIDReader {
    /// UUIDs of every slice, or an empty set when the file cannot be read or is not Mach-O.
    static func uuids(ofFileAt url: URL) -> Set<UUID> {
        guard let fileData = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        return uuids(in: fileData)
    }

    static func uuids(in fileData: Data) -> Set<UUID> {
        guard let magic = fileData.readUInt32(at: 0, bigEndian: false) else { return [] }

        switch magic {
        case FAT_CIGAM, FAT_MAGIC:
            // Fat headers are stored big-endian, so on a little-endian Mac the magic reads as
            // `FAT_CIGAM` and the table after it is read big-endian.
            return uuidsOfFatFile(fileData, archEntrySize: MemoryLayout<fat_arch>.size, offsetIs64Bit: false)
        case FAT_CIGAM_64, FAT_MAGIC_64:
            return uuidsOfFatFile(fileData, archEntrySize: MemoryLayout<fat_arch_64>.size, offsetIs64Bit: true)
        default:
            return uuidOfThinImage(fileData, at: 0).map { [$0] } ?? []
        }
    }

    private static func uuidsOfFatFile(_ fileData: Data, archEntrySize: Int, offsetIs64Bit: Bool) -> Set<UUID> {
        guard let archCount = fileData.readUInt32(at: 4, bigEndian: true) else { return [] }
        var sliceUUIDs: Set<UUID> = []
        for archIndex in 0..<Int(archCount) {
            let entryOffset = MemoryLayout<fat_header>.size + archIndex * archEntrySize
            // Both layouts start with cputype and cpusubtype; the offset follows them.
            let sliceOffset: UInt64?
            if offsetIs64Bit {
                sliceOffset = fileData.readUInt64(at: entryOffset + 8, bigEndian: true)
            } else {
                sliceOffset = fileData.readUInt32(at: entryOffset + 8, bigEndian: true).map(UInt64.init)
            }
            guard let sliceOffset, let sliceUUID = uuidOfThinImage(fileData, at: Int(sliceOffset)) else { continue }
            sliceUUIDs.insert(sliceUUID)
        }
        return sliceUUIDs
    }

    /// The UUID of the 64-bit image starting at `imageOffset`, in the file's native little-endian order.
    private static func uuidOfThinImage(_ fileData: Data, at imageOffset: Int) -> UUID? {
        guard
            fileData.readUInt32(at: imageOffset, bigEndian: false) == MH_MAGIC_64,
            let commandCount = fileData.readUInt32(at: imageOffset + 16, bigEndian: false)
        else { return nil }

        var commandOffset = imageOffset + MemoryLayout<mach_header_64>.size
        for _ in 0..<commandCount {
            guard
                let command = fileData.readUInt32(at: commandOffset, bigEndian: false),
                let commandSize = fileData.readUInt32(at: commandOffset + 4, bigEndian: false),
                commandSize >= 8
            else { return nil }

            if command == UInt32(LC_UUID) {
                let uuidStart = commandOffset + 8
                guard uuidStart + 16 <= fileData.count else { return nil }
                let uuidBytes = Array(fileData[(fileData.startIndex + uuidStart)..<(fileData.startIndex + uuidStart + 16)])
                return UUID(uuid: (
                    uuidBytes[0], uuidBytes[1], uuidBytes[2], uuidBytes[3],
                    uuidBytes[4], uuidBytes[5], uuidBytes[6], uuidBytes[7],
                    uuidBytes[8], uuidBytes[9], uuidBytes[10], uuidBytes[11],
                    uuidBytes[12], uuidBytes[13], uuidBytes[14], uuidBytes[15]
                ))
            }
            commandOffset += Int(commandSize)
        }
        return nil
    }
}

private extension Data {
    func readUInt32(at offset: Int, bigEndian: Bool) -> UInt32? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        let value = self[(startIndex + offset)..<(startIndex + offset + 4)]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
    }

    func readUInt64(at offset: Int, bigEndian: Bool) -> UInt64? {
        guard offset >= 0, offset + 8 <= count else { return nil }
        let value = self[(startIndex + offset)..<(startIndex + offset + 8)]
            .withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) }
        return bigEndian ? UInt64(bigEndian: value) : UInt64(littleEndian: value)
    }
}
