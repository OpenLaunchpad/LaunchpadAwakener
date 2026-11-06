import Foundation
import MachO
import OSToolbox

/// Facts about one build of the Dock that cannot be discovered at run time.
///
/// The payload installs nothing on a Dock build missing from ``knownProfiles``: every fact here
/// belongs to one build — an address inside the Dock's image means nothing in any other. Supporting a
/// new macOS build means checking each fact against that build and adding its profile.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockBuildProfile")
struct DockBuildProfile: Sendable, Equatable {
    /// `LC_UUID` of the Dock executable's arm64e slice, which identifies the build.
    let executableUUID: UUID

    /// `CFBundleVersion` of Dock.app. Only written to the log.
    let bundleVersion: String

    /// Unslid address of the global that holds the Dock's `DockBar`; nothing exported leads to it.
    ///
    /// The Dock's own code loads `DockBar` from this global, for example in
    /// `-[DockBarSystemDefinedEventHandler handleSystemDefinedEvent:type:]`.
    let dockBarGlobalAddress: UInt

    /// Unslid address of the global that holds the Dock's `DockGlobals`.
    ///
    /// `+[DockGlassMaterialLayerController currentDockMaterialEnvironmentWithColorScheme:]` reads it, and
    /// the `DockBar` global, and traps when either is still empty; the payload checks both first.
    let dockGlobalsGlobalAddress: UInt

    static let knownProfiles: [DockBuildProfile] = [
        // macOS 27.2 (26B123).
        DockBuildProfile(
            executableUUID: UUID(uuidString: "C53975B1-2956-3ED4-B699-D4CE2E6A602C")!,
            bundleVersion: "2571.1.32.402",
            dockBarGlobalAddress: 0x1_0032_9BA8,
            dockGlobalsGlobalAddress: 0x1_0032_9C20
        ),
    ]

    /// The running Dock's profile, or nil when this build is not one of ``knownProfiles``.
    static let current: DockBuildProfile? = resolveCurrentProfile()

    /// How far the Dock executable was slid when loaded; added to every address in a profile.
    static var executableSlide: Int {
        _dyld_get_image_vmaddr_slide(0)
    }

    private static func resolveCurrentProfile() -> DockBuildProfile? {
        // dyld always lists the main executable first.
        guard
            let executableHeader = _dyld_get_image_header(0),
            let executableUUID = MachOImageInspector.uuid(ofImageWithHeader: executableHeader)
        else {
            #log(.error, "Could not read the executable's UUID")
            return nil
        }
        guard let profile = knownProfiles.first(where: { $0.executableUUID == executableUUID }) else {
            #log(.error, "Unknown Dock build \(executableUUID.uuidString, privacy: .public); this payload knows none of its facts")
            return nil
        }
        #log(.info, "Dock build \(profile.bundleVersion, privacy: .public) (\(executableUUID.uuidString, privacy: .public))")
        return profile
    }
}

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
