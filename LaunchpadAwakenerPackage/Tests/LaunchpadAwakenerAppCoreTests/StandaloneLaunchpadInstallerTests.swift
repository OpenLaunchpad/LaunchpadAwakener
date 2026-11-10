import Foundation
import Testing
@testable import LaunchpadAwakenerAppCore

/// Installing the standalone Launchpad from the archive embedded in the injected app, and recognising an
/// installed copy. Every test works in a temporary directory of its own, with stand-in apps that hold only
/// an `Info.plist`.
@Suite("Installing the standalone Launchpad")
final class StandaloneLaunchpadInstallerTests {
    private typealias Installer = StandaloneLaunchpadInstaller

    private let workingDirectoryURL: URL

    init() throws {
        workingDirectoryURL = URL.temporaryDirectory.appending(path: "StandaloneLaunchpadInstallerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workingDirectoryURL, withIntermediateDirectories: true)
    }

    deinit {
        try? FileManager.default.removeItem(at: workingDirectoryURL)
    }

    private func directory(_ name: String) throws -> URL {
        let directoryURL = workingDirectoryURL.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        return directoryURL
    }

    /// A stand-in app: `Launchpad.app/Contents/Info.plist` with `bundleIdentifier`.
    @discardableResult
    private func makeApplication(in directoryURL: URL, bundleIdentifier: String = Installer.bundleIdentifier) throws -> URL {
        let applicationURL = directoryURL.appending(path: Installer.applicationFileName, directoryHint: .isDirectory)
        let contentsURL = applicationURL.appending(path: "Contents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        let propertyList = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": bundleIdentifier], format: .xml, options: 0)
        try propertyList.write(to: contentsURL.appending(path: "Info.plist", directoryHint: .notDirectory))
        return applicationURL
    }

    /// The archive the build embeds: the app zipped with its folder, as `ditto -c -k --keepParent` makes it.
    private func makeArchive(bundleIdentifier: String = Installer.bundleIdentifier) async throws -> URL {
        let applicationURL = try makeApplication(in: try directory("Build"), bundleIdentifier: bundleIdentifier)
        let archiveURL = workingDirectoryURL.appending(path: "Launchpad.zip", directoryHint: .notDirectory)
        let terminationStatus = try await Installer.run(URL(filePath: "/usr/bin/ditto"), arguments: ["-c", "-k", "--keepParent", applicationURL.path, archiveURL.path])
        try #require(terminationStatus == 0)
        return archiveURL
    }

    @Test("the archive unpacks into the Applications folder")
    func installsIntoApplications() async throws {
        let applicationsURL = try directory("Applications")
        let installer = Installer(archiveURL: try await makeArchive(), applicationsDirectories: [applicationsURL])

        let installedURL = try await installer.install()

        #expect(installedURL == applicationsURL.appending(path: "Launchpad.app", directoryHint: .isDirectory))
        #expect(Installer.isStandaloneApplication(at: installedURL))
        #expect(try FileManager.default.contentsOfDirectory(atPath: applicationsURL.path) == ["Launchpad.app"])
    }

    @Test("a user who cannot write to the first Applications folder gets the app in the next")
    func fallsBackToTheNextApplicationsFolder() async throws {
        let systemApplicationsURL = try directory("SystemApplications")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: systemApplicationsURL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: systemApplicationsURL.path) }
        let userApplicationsURL = workingDirectoryURL.appending(path: "UserApplications", directoryHint: .isDirectory)
        let installer = Installer(archiveURL: try await makeArchive(), applicationsDirectories: [systemApplicationsURL, userApplicationsURL])

        let installedURL = try await installer.install()

        #expect(installedURL.deletingLastPathComponent().standardizedFileURL == userApplicationsURL.standardizedFileURL)
        #expect(Installer.isStandaloneApplication(at: installedURL))
    }

    @Test("a copy already in the Applications folder is kept as it is")
    func keepsAnInstalledCopy() async throws {
        let applicationsURL = try directory("Applications")
        let existingURL = try makeApplication(in: applicationsURL)
        let marker = existingURL.appending(path: "Contents/Marker", directoryHint: .notDirectory)
        try Data().write(to: marker)
        let installer = Installer(archiveURL: try await makeArchive(), applicationsDirectories: [applicationsURL])

        #expect(try await installer.install() == existingURL)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test("another app named Launchpad is not replaced")
    func doesNotReplaceAnotherApplication() async throws {
        let applicationsURL = try directory("Applications")
        let otherURL = try makeApplication(in: applicationsURL, bundleIdentifier: "com.example.launchpad")
        let installer = Installer(archiveURL: try await makeArchive(), applicationsDirectories: [applicationsURL])

        await #expect(throws: Installer.InstallationError.destinationTaken(path: otherURL.path)) {
            try await installer.install()
        }
    }

    @Test("an archive that holds some other app installs nothing")
    func refusesAnArchiveOfAnotherApplication() async throws {
        let applicationsURL = try directory("Applications")
        let installer = Installer(archiveURL: try await makeArchive(bundleIdentifier: "com.example.other"), applicationsDirectories: [applicationsURL])

        await #expect(throws: Installer.InstallationError.archiveHoldsNoStandaloneApplication) {
            try await installer.install()
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: applicationsURL.path).isEmpty)
    }

    @Test("a build without the archive cannot install")
    @MainActor
    func needsTheArchive() async throws {
        let installer = Installer(archiveURL: nil, applicationsDirectories: [try directory("Applications")])

        #expect(!StandaloneLaunchpadController(installer: installer).canInstall)
        await #expect(throws: Installer.InstallationError.archiveMissing) {
            try await installer.install()
        }
    }

    @Test("an installed copy is found where LaunchServices knows it, or else in an Applications folder")
    func findsAnInstalledCopy() throws {
        let applicationsURL = try directory("Applications")
        let installer = Installer(archiveURL: nil, applicationsDirectories: [applicationsURL])
        #expect(installer.installedApplicationURL(registeredApplicationURLs: []) == nil)

        let elsewhereURL = try makeApplication(in: try directory("Elsewhere"))
        #expect(installer.installedApplicationURL(registeredApplicationURLs: [elsewhereURL]) == elsewhereURL)

        // Copies LaunchServices still remembers after they were deleted or put in the Trash do not count.
        let deletedURL = workingDirectoryURL.appending(path: "Deleted/Launchpad.app", directoryHint: .isDirectory)
        let trashedURL = try makeApplication(in: try directory(".Trash"))
        let installedURL = try makeApplication(in: applicationsURL)
        #expect(installer.installedApplicationURL(registeredApplicationURLs: [deletedURL, trashedURL]) == installedURL)
    }
}
