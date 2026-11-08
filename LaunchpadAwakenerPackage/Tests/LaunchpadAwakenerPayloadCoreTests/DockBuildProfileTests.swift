import Foundation
@testable import LaunchpadAwakenerPayloadCore
import Testing

/// The table of Dock builds the payload knows.
///
/// Every address in it was read out of that build's own binary — the steps and the evidence are in the
/// implementation note and in `/Volumes/RE/Dock/<version>/README.md` — so nothing here can check the
/// facts themselves. What these tests hold the table to is coverage, and the shape of each entry: a
/// typo in a hand-copied UUID or address should fail here, not in someone's Dock.
@Suite("Dock build profiles")
struct DockBuildProfileTests {
    /// Every macOS release from 26.0 to 27.2 with its build number, as AppleDB lists the full update
    /// packages, including the builds made only for particular Mac models.
    static let supportedReleases = [
        "26.0 (25A354)",
        "26.0.1 (25A362)",
        "26.0.1 (25A8364)",
        "26.1 (25B78)",
        "26.2 (25C56)",
        "26.3 (25D125)",
        "26.3.1 (25D2128)",
        "26.3.2 (25D2140)",
        "26.4 (25E246)",
        "26.4.1 (25E253)",
        "26.5 (25F71)",
        "26.5.1 (25F80)",
        "26.5.2 (25F84)",
        "26.6 (25G72)",
        "26.6.1 (25G76)",
        "26.6.2 (25G83)",
        "26.7 (25G229)",
        "26.7.1 (25G241)",
        "26.7.2 (25G332)",
        "27.0 (26A428)",
        "27.0.1 (26A434)",
        "27.2 (26B123)",
        "27.2 (26B7124)",
        "27.2 (26B8125)",
    ]

    @Test("every macOS release from 26.0 to 27.2 has the profile of its Dock", arguments: supportedReleases)
    func releaseHasProfile(release: String) {
        let coveringProfiles = DockBuildProfile.knownProfiles.filter { $0.systemReleases.contains(release) }
        #expect(coveringProfiles.count == 1, "\(release) is covered by \(coveringProfiles.count) profiles")
    }

    @Test("the table names no release outside the supported list")
    func noUnexpectedRelease() {
        let listedReleases = DockBuildProfile.knownProfiles.flatMap(\.systemReleases)
        #expect(Set(listedReleases).subtracting(Self.supportedReleases).isEmpty)
    }

    @Test("a Dock is found by the UUID of its arm64e slice")
    func lookupByUUID() throws {
        let macOS26Point7Dock = try #require(UUID(uuidString: "073A7E75-21BB-3427-8180-9B9B3B80212B"))
        let profile = try #require(DockBuildProfile.knownProfile(forExecutableUUID: macOS26Point7Dock))
        #expect(profile.systemReleases.contains("26.7 (25G229)"))
    }

    @Test("a Dock missing from the table gets no profile")
    func unknownBuildIsRejected() {
        #expect(DockBuildProfile.knownProfile(forExecutableUUID: UUID()) == nil)
    }

    @Test("no build is listed twice")
    func buildsAreUnique() {
        let executableUUIDs = DockBuildProfile.knownProfiles.map(\.executableUUID)
        #expect(Set(executableUUIDs).count == executableUUIDs.count)
    }

    @Test("both globals are distinct pointer-sized slots inside the executable", arguments: DockBuildProfile.knownProfiles)
    func globalAddressesAreWellFormed(profile: DockBuildProfile) {
        let executableBaseAddress: UInt = 0x1_0000_0000
        let pointerSize = UInt(MemoryLayout<UnsafeRawPointer>.size)
        for globalAddress in [profile.dockBarGlobalAddress, profile.dockGlobalsGlobalAddress] {
            #expect(globalAddress > executableBaseAddress)
            #expect(globalAddress < executableBaseAddress + 0x1000_0000)
            #expect(globalAddress % pointerSize == 0)
        }
        #expect(profile.dockBarGlobalAddress != profile.dockGlobalsGlobalAddress)
    }

    @Test("DockGlobals is Objective-C on macOS 26 and Swift on macOS 27", arguments: DockBuildProfile.knownProfiles)
    func dockGlobalsClassMatchesTheMajorVersion(profile: DockBuildProfile) {
        let majorVersions = Set(profile.systemReleases.map { $0.prefix { $0 != "." } })
        #expect(majorVersions.count == 1, "\(profile.executableUUID) spans macOS \(majorVersions.sorted())")
        let expectedClassName = majorVersions == ["26"]
            ? DockBuildProfile.objectiveCDockGlobalsClassName
            : DockBuildProfile.swiftDockGlobalsClassName
        #expect(profile.dockGlobalsClassName == expectedClassName)
    }
}

extension DockBuildProfile: CustomTestStringConvertible {
    public var testDescription: String {
        "Dock \(bundleVersion) of macOS \(systemReleases.joined(separator: ", "))"
    }
}
