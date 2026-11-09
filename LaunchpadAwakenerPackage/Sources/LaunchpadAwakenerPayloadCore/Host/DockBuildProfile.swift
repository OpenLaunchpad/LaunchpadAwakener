import Foundation
import MachO
import OSToolbox

/// Facts about one build of the Dock that cannot be discovered at run time.
///
/// The payload installs nothing on a Dock build missing from ``knownProfiles``: every fact here
/// belongs to one build — an address inside the Dock's image means nothing in any other. Supporting a
/// new macOS build means checking each fact against that build and adding its profile; the
/// implementation note's section on adapting to a new Dock build lists the steps.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockBuildProfile")
struct DockBuildProfile: Sendable, Equatable {
    /// `LC_UUID` of the Dock executable's arm64e slice, which identifies the build.
    let executableUUID: UUID

    /// The macOS releases, with their build numbers, that ship this Dock. Written to the log and
    /// reported to the app.
    ///
    /// Point releases often ship a byte-identical Dock, so one profile can cover several.
    let systemReleases: [String]

    /// `CFBundleVersion` of Dock.app. Written to the log and reported to the app.
    let bundleVersion: String

    /// Unslid address of the global that holds the Dock's `DockBar`; nothing exported leads to it.
    ///
    /// The Dock's own code loads `DockBar` from this global, for example in
    /// `-[DockBarSystemDefinedEventHandler handleSystemDefinedEvent:type:]`.
    let dockBarGlobalAddress: UInt

    /// Unslid address of the global that holds the Dock's `DockGlobals`.
    ///
    /// On macOS 27, `+[DockGlassMaterialLayerController currentDockMaterialEnvironmentWithColorScheme:]`
    /// reads it, and the `DockBar` global, and traps when either is still empty; the payload checks both
    /// first. The Dock's own code loads it next to `DockBar` in
    /// `-[DockBarSystemDefinedEventHandler handleSystemDefinedEvent:type:]`, on 26 and 27 alike.
    let dockGlobalsGlobalAddress: UInt

    /// The class of the object in the `DockGlobals` global, as `NSClassFromString` looks it up.
    ///
    /// macOS 26 has an Objective-C class; macOS 27 rewrote it in Swift, whose runtime name is mangled.
    let dockGlobalsClassName: String

    static let objectiveCDockGlobalsClassName = "DockGlobals"
    static let swiftDockGlobalsClassName = "_TtC8DockCore11DockGlobals"

    /// Every Dock of a macOS release from 26.0 to 27.2. Each entry's binary, headers and IDA database are
    /// in a directory of `/Volumes/RE/Dock/` named after one of its releases; that directory's README
    /// lists every release the build shipped in and where the two addresses were read.
    ///
    /// An entry whose UUID does not parse is left out rather than trapping: this table is built inside the
    /// Dock. The tests' release list notices the gap.
    static let knownProfiles: [DockBuildProfile] = [
        macOS26Profile(
            executableUUID: "83B28856-398F-308D-97B5-D1E807EB4A82",
            systemReleases: ["26.0 (25A354)", "26.0.1 (25A362)"],
            bundleVersion: "2427.0.4",
            dockBarGlobalAddress: 0x1_0048_3FF8,
            dockGlobalsGlobalAddress: 0x1_0048_40C0
        ),
        // Built only for Mac17,2.
        macOS26Profile(
            executableUUID: "95B0A32D-9192-3E9F-88E5-326D78A47B10",
            systemReleases: ["26.0.1 (25A8364)"],
            bundleVersion: "2427.0.4",
            dockBarGlobalAddress: 0x1_0048_3FF8,
            dockGlobalsGlobalAddress: 0x1_0048_40C0
        ),
        macOS26Profile(
            executableUUID: "CA84BDA7-CE07-316A-8F79-BE09C6343DA3",
            systemReleases: ["26.1 (25B78)"],
            bundleVersion: "2427.1.14",
            dockBarGlobalAddress: 0x1_0048_C068,
            dockGlobalsGlobalAddress: 0x1_0048_C130
        ),
        macOS26Profile(
            executableUUID: "BDEEACD1-0E93-31B1-97E2-C83454AA5631",
            systemReleases: ["26.2 (25C56)"],
            bundleVersion: "2427.2.4",
            dockBarGlobalAddress: 0x1_0048_C058,
            dockGlobalsGlobalAddress: 0x1_0048_C120
        ),
        macOS26Profile(
            executableUUID: "B3F20C91-3703-3A12-82CB-9815D5637587",
            systemReleases: ["26.3 (25D125)"],
            bundleVersion: "2427.2.4",
            dockBarGlobalAddress: 0x1_0048_C058,
            dockGlobalsGlobalAddress: 0x1_0048_C120
        ),
        macOS26Profile(
            executableUUID: "A69280A2-BE16-31AD-8D31-B3AEC7D6A519",
            // 26.3.2 was built only for Mac17,5, with the same Dock.
            systemReleases: ["26.3.1 (25D2128)", "26.3.2 (25D2140)"],
            bundleVersion: "2427.2.4.101",
            dockBarGlobalAddress: 0x1_0048_C058,
            dockGlobalsGlobalAddress: 0x1_0048_C120
        ),
        macOS26Profile(
            executableUUID: "C64463EE-8697-38E1-B00E-81C2FA6AF081",
            systemReleases: ["26.4 (25E246)", "26.4.1 (25E253)"],
            bundleVersion: "2427.4.7",
            dockBarGlobalAddress: 0x1_0048_7FE0,
            dockGlobalsGlobalAddress: 0x1_0048_80A8
        ),
        macOS26Profile(
            executableUUID: "5DF5CC12-1875-3DEA-9DF7-48A3F8BEF94D",
            systemReleases: ["26.5 (25F71)", "26.5.1 (25F80)", "26.5.2 (25F84)"],
            bundleVersion: "2427.4.7",
            dockBarGlobalAddress: 0x1_0048_7FE0,
            dockGlobalsGlobalAddress: 0x1_0048_80A8
        ),
        macOS26Profile(
            executableUUID: "435AEE1F-9C52-3AD2-8D6A-4356EDFB4818",
            systemReleases: ["26.6 (25G72)", "26.6.1 (25G76)"],
            bundleVersion: "2427.6",
            dockBarGlobalAddress: 0x1_0048_7FE0,
            dockGlobalsGlobalAddress: 0x1_0048_80A8
        ),
        macOS26Profile(
            executableUUID: "92E4C43E-E84A-3461-85B0-A780A8B56942",
            systemReleases: ["26.6.2 (25G83)"],
            bundleVersion: "2427.6",
            dockBarGlobalAddress: 0x1_0048_7FE0,
            dockGlobalsGlobalAddress: 0x1_0048_80A8
        ),
        macOS26Profile(
            executableUUID: "073A7E75-21BB-3427-8180-9B9B3B80212B",
            systemReleases: ["26.7 (25G229)", "26.7.1 (25G241)"],
            bundleVersion: "2427.6",
            dockBarGlobalAddress: 0x1_0048_7FE0,
            dockGlobalsGlobalAddress: 0x1_0048_80A8
        ),
        macOS26Profile(
            executableUUID: "6FE4526D-1910-3D6D-9BD4-7D71E943F5A2",
            systemReleases: ["26.7.2 (25G332)"],
            bundleVersion: "2427.6",
            dockBarGlobalAddress: 0x1_0048_7FE0,
            dockGlobalsGlobalAddress: 0x1_0048_80A8
        ),
        macOS27Profile(
            executableUUID: "3BDF6A3B-866B-3C07-920C-E9E7FB57B56B",
            systemReleases: ["27.0 (26A428)", "27.0.1 (26A434)"],
            bundleVersion: "2571.0.6.402",
            dockBarGlobalAddress: 0x1_0040_9B78,
            dockGlobalsGlobalAddress: 0x1_0040_9C28
        ),
        macOS27Profile(
            executableUUID: "C53975B1-2956-3ED4-B699-D4CE2E6A602C",
            systemReleases: ["27.2 (26B123)"],
            bundleVersion: "2571.1.32.402",
            dockBarGlobalAddress: 0x1_0032_9BA8,
            dockGlobalsGlobalAddress: 0x1_0032_9C20
        ),
        // Built only for Mac18,1 and Mac18,2.
        macOS27Profile(
            executableUUID: "F803F947-3163-3ADA-ADAB-291E53BE915F",
            systemReleases: ["27.2 (26B7124)"],
            bundleVersion: "2571.1.32.402",
            dockBarGlobalAddress: 0x1_0033_6F08,
            dockGlobalsGlobalAddress: 0x1_0033_6F80
        ),
        // Built only for Mac17,10 to Mac17,13.
        macOS27Profile(
            executableUUID: "62EF1602-09F4-3C94-92B1-CFB91EC1CF0E",
            systemReleases: ["27.2 (26B8125)"],
            bundleVersion: "2571.1.32.402",
            dockBarGlobalAddress: 0x1_0033_6F08,
            dockGlobalsGlobalAddress: 0x1_0033_6F80
        ),
    ].compactMap(\.self)

    /// A Dock of macOS 26, where `DockGlobals` is an Objective-C class.
    private static func macOS26Profile(
        executableUUID: String,
        systemReleases: [String],
        bundleVersion: String,
        dockBarGlobalAddress: UInt,
        dockGlobalsGlobalAddress: UInt
    ) -> DockBuildProfile? {
        UUID(uuidString: executableUUID).map { parsedExecutableUUID in
            DockBuildProfile(
                executableUUID: parsedExecutableUUID,
                systemReleases: systemReleases,
                bundleVersion: bundleVersion,
                dockBarGlobalAddress: dockBarGlobalAddress,
                dockGlobalsGlobalAddress: dockGlobalsGlobalAddress,
                dockGlobalsClassName: objectiveCDockGlobalsClassName
            )
        }
    }

    /// A Dock of macOS 27, where `DockGlobals` is a Swift class.
    private static func macOS27Profile(
        executableUUID: String,
        systemReleases: [String],
        bundleVersion: String,
        dockBarGlobalAddress: UInt,
        dockGlobalsGlobalAddress: UInt
    ) -> DockBuildProfile? {
        UUID(uuidString: executableUUID).map { parsedExecutableUUID in
            DockBuildProfile(
                executableUUID: parsedExecutableUUID,
                systemReleases: systemReleases,
                bundleVersion: bundleVersion,
                dockBarGlobalAddress: dockBarGlobalAddress,
                dockGlobalsGlobalAddress: dockGlobalsGlobalAddress,
                dockGlobalsClassName: swiftDockGlobalsClassName
            )
        }
    }

    /// The running Dock's profile, or nil when this build is not one of ``knownProfiles``.
    static let current: DockBuildProfile? = resolveCurrentProfile()

    /// `LC_UUID` of the running executable's slice, profiled or not. Nil when it cannot be read.
    static var currentExecutableUUID: UUID? {
        // dyld always lists the main executable first.
        _dyld_get_image_header(0).flatMap(MachOImageInspector.uuid(ofImageWithHeader:))
    }

    /// How far the Dock executable was slid when loaded; added to every address in a profile.
    static var executableSlide: Int {
        _dyld_get_image_vmaddr_slide(0)
    }

    /// The profile of the Dock build whose arm64e slice has `executableUUID`, or nil when it is not known.
    static func knownProfile(forExecutableUUID executableUUID: UUID) -> DockBuildProfile? {
        knownProfiles.first { $0.executableUUID == executableUUID }
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
        guard let profile = knownProfile(forExecutableUUID: executableUUID) else {
            #log(.error, "Unknown Dock build \(executableUUID.uuidString, privacy: .public); this payload knows none of its facts")
            return nil
        }
        #log(.info, "Dock build \(profile.bundleVersion, privacy: .public) of macOS \(profile.systemReleases.joined(separator: ", "), privacy: .public) (\(executableUUID.uuidString, privacy: .public))")
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
