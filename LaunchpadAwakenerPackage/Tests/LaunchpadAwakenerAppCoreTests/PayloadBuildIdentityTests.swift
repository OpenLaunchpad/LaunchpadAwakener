import Foundation
import MachO
import Testing
@testable import LaunchpadAwakenerAppCore

/// Covers telling a resident payload from this app's own build: reading the bundled payload's slice
/// UUIDs, and the comparison that decides "outdated".
@Suite("Payload build identity")
struct PayloadBuildIdentityTests {
    private static let firstSliceUUID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let secondSliceUUID = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!

    /// The real thing: the file this test process was loaded from must contain the UUID dyld reports
    /// for the image it mapped from it.
    @Test("The running executable's file contains its own UUID")
    func runningExecutableContainsItsUUID() throws {
        let header = try #require(_dyld_get_image_header(0))
        let path = String(cString: try #require(_dyld_get_image_name(0)))
        let mappedUUID = try #require(Self.uuid(ofMappedImage: header))

        #expect(MachOFileUUIDReader.uuids(ofFileAt: URL(fileURLWithPath: path)).contains(mappedUUID))
    }

    @Test("A thin image yields its one UUID")
    func thinImageYieldsItsUUID() {
        #expect(MachOFileUUIDReader.uuids(in: Self.thinImage(uuid: Self.firstSliceUUID)) == [Self.firstSliceUUID])
    }

    /// The payload ships universal — x86_64, arm64 and arm64e, each linked separately with its own
    /// UUID — and the Dock runs whichever slice suits it. Any of them is "this build".
    @Test("A universal file yields every slice's UUID")
    func universalFileYieldsEverySlice() {
        let fileData = Self.universalFile(slices: [
            Self.thinImage(uuid: Self.firstSliceUUID),
            Self.thinImage(uuid: Self.secondSliceUUID),
        ])

        #expect(MachOFileUUIDReader.uuids(in: fileData) == [Self.firstSliceUUID, Self.secondSliceUUID])
    }

    @Test("Something that is not Mach-O yields nothing")
    func nonMachOYieldsNothing() {
        #expect(MachOFileUUIDReader.uuids(in: Data("not a binary".utf8)).isEmpty)
        #expect(MachOFileUUIDReader.uuids(in: Data()).isEmpty)
        #expect(MachOFileUUIDReader.uuids(ofFileAt: URL(fileURLWithPath: "/nonexistent/payload")).isEmpty)
    }

    @Test("A truncated image yields nothing rather than reading past the end")
    func truncatedImageYieldsNothing() {
        let image = Self.thinImage(uuid: Self.firstSliceUUID)
        #expect(MachOFileUUIDReader.uuids(in: image.prefix(image.count - 4)).isEmpty)
    }

    @Test("A payload is outdated only when its UUID is none of the bundled slices")
    func staleOnlyWhenNoSliceMatches() {
        let bundled: Set<UUID> = [Self.firstSliceUUID, Self.secondSliceUUID]

        #expect(!PayloadInjectionCoordinator.isStale(imageUUID: Self.secondSliceUUID, bundledImageUUIDs: bundled))
        #expect(PayloadInjectionCoordinator.isStale(imageUUID: UUID(), bundledImageUUIDs: bundled))
    }

    /// With nothing to compare against, calling every payload outdated would have the user
    /// restarting the Dock for no reason.
    @Test("An unreadable bundled payload makes nothing outdated")
    func unreadableBundleMakesNothingStale() {
        #expect(!PayloadInjectionCoordinator.isStale(imageUUID: UUID(), bundledImageUUIDs: []))
    }

    // MARK: - Building Mach-O files by hand

    /// A 64-bit image whose only load command is `LC_UUID`, in the little-endian order Macs write.
    private static func thinImage(uuid: UUID) -> Data {
        var data = Data()
        data.appendLittleEndian(MH_MAGIC_64)
        data.appendLittleEndian(UInt32(bitPattern: CPU_TYPE_ARM64))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(MH_DYLIB))
        data.appendLittleEndian(UInt32(1))
        data.appendLittleEndian(UInt32(MemoryLayout<uuid_command>.size))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(0))
        data.appendLittleEndian(UInt32(LC_UUID))
        data.appendLittleEndian(UInt32(MemoryLayout<uuid_command>.size))
        withUnsafeBytes(of: uuid.uuid) { data.append(contentsOf: $0) }
        return data
    }

    /// A fat file with `slices` laid out one after another, its header in big-endian order.
    private static func universalFile(slices: [Data]) -> Data {
        let headerSize = MemoryLayout<fat_header>.size + slices.count * MemoryLayout<fat_arch>.size
        var data = Data()
        data.appendBigEndian(FAT_MAGIC)
        data.appendBigEndian(UInt32(slices.count))
        var sliceOffset = headerSize
        for slice in slices {
            data.appendBigEndian(UInt32(bitPattern: CPU_TYPE_ARM64))
            data.appendBigEndian(UInt32(0))
            data.appendBigEndian(UInt32(sliceOffset))
            data.appendBigEndian(UInt32(slice.count))
            data.appendBigEndian(UInt32(0))
            sliceOffset += slice.count
        }
        slices.forEach { data.append($0) }
        return data
    }

    private static func uuid(ofMappedImage header: UnsafePointer<mach_header>) -> UUID? {
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

private extension Data {
    mutating func appendLittleEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendBigEndian(_ value: UInt32) {
        Swift.withUnsafeBytes(of: value.bigEndian) { append(contentsOf: $0) }
    }
}
