import Foundation

/// Installs the standalone Launchpad from the copy embedded in this app, `Contents/Resources/Launchpad.zip`,
/// which the build makes from the standalone target.
///
/// A zip rather than the app itself: an app inside this one risks being registered by LaunchServices and
/// listed by Spotlight as a second Launchpad, one that would run from inside this bundle.
public struct StandaloneLaunchpadInstaller: Sendable {
    public enum InstallationError: Error, LocalizedError, Equatable {
        /// This build of the app did not embed the standalone one.
        case archiveMissing
        case noWritableApplicationsDirectory
        case unpackingFailed(terminationStatus: Int32)
        /// The archive unpacked to something other than the standalone app.
        case archiveHoldsNoStandaloneApplication
        /// Another app already has the standalone app's name in the Applications folder.
        case destinationTaken(path: String)

        public var errorDescription: String? {
            switch self {
            case .archiveMissing:
                "This build of LaunchpadAwakener does not include the standalone app."
            case .noWritableApplicationsDirectory:
                "Neither /Applications nor ~/Applications can be written to."
            case .unpackingFailed(let terminationStatus):
                "Unpacking the standalone app failed (ditto exited with status \(terminationStatus))."
            case .archiveHoldsNoStandaloneApplication:
                "The embedded archive does not hold the standalone app."
            case .destinationTaken(let path):
                "Another app is already at \(path)."
            }
        }
    }

    /// Must match the standalone target's `PRODUCT_BUNDLE_IDENTIFIER`.
    public static let bundleIdentifier = {
        #if DEBUG
        "com.MxIris.LaunchpadAwakener.Launchpad.debug"
        #else
        "com.MxIris.LaunchpadAwakener.Launchpad"
        #endif
    }()

    /// The app's file name, which the archive unpacks to and the Applications folder keeps.
    static let applicationFileName = "Launchpad.app"

    /// The embedded archive; nil in a build that did not embed it.
    public let archiveURL: URL?
    /// Where to install, in order of preference: the first one this user may write to takes it.
    let applicationsDirectories: [URL]

    public init(
        archiveURL: URL? = Bundle.main.url(forResource: "Launchpad", withExtension: "zip"),
        applicationsDirectories: [URL] = [
            URL(filePath: "/Applications", directoryHint: .isDirectory),
            FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications", directoryHint: .isDirectory),
        ]
    ) {
        self.archiveURL = archiveURL
        self.applicationsDirectories = applicationsDirectories
    }

    /// The installed standalone app: the first copy LaunchServices knows of, or else one in an Applications
    /// folder, which finds a copy LaunchServices has not registered yet.
    public func installedApplicationURL(registeredApplicationURLs: [URL]) -> URL? {
        let candidateURLs = registeredApplicationURLs + applicationsDirectories.map { $0.appending(path: Self.applicationFileName, directoryHint: .isDirectory) }
        return candidateURLs.first { Self.isStandaloneApplication(at: $0) }
    }

    /// Unpacks the embedded app into the first Applications folder this user may write to and returns where
    /// it went. A copy of it already there is kept as it is.
    public func install() async throws -> URL {
        guard let archiveURL else { throw InstallationError.archiveMissing }
        guard let applicationsDirectory = writableApplicationsDirectory() else { throw InstallationError.noWritableApplicationsDirectory }
        let destinationURL = applicationsDirectory.appending(path: Self.applicationFileName, directoryHint: .isDirectory)
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            guard Self.isStandaloneApplication(at: destinationURL) else { throw InstallationError.destinationTaken(path: destinationURL.path) }
            return destinationURL
        }

        // Unpacked beside the destination, on the same volume, then moved into place at once: an
        // interrupted unpacking never leaves half an app in the Applications folder.
        let stagingDirectoryURL = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: destinationURL, create: true)
        defer { try? FileManager.default.removeItem(at: stagingDirectoryURL) }
        try await Self.unpack(archiveURL, into: stagingDirectoryURL)
        let unpackedApplicationURL = stagingDirectoryURL.appending(path: Self.applicationFileName, directoryHint: .isDirectory)
        guard Self.isStandaloneApplication(at: unpackedApplicationURL) else { throw InstallationError.archiveHoldsNoStandaloneApplication }
        try FileManager.default.moveItem(at: unpackedApplicationURL, to: destinationURL)
        return destinationURL
    }

    /// `/Applications` for an administrator; otherwise `~/Applications`, made if it is not there yet.
    private func writableApplicationsDirectory() -> URL? {
        applicationsDirectories.first { directoryURL in
            if !FileManager.default.fileExists(atPath: directoryURL.path) {
                try? FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            }
            return FileManager.default.isWritableFile(atPath: directoryURL.path)
        }
    }

    /// Whether `url` holds the standalone app: on disk, out of the Trash, with its bundle identifier. Reads
    /// `Info.plist` itself, since `Bundle` caches by path and would still report a copy deleted meanwhile.
    static func isStandaloneApplication(at url: URL) -> Bool {
        guard !url.pathComponents.contains(".Trash") else { return false }
        let informationPropertyListURL = url.appending(path: "Contents/Info.plist", directoryHint: .notDirectory)
        guard
            let data = try? Data(contentsOf: informationPropertyListURL),
            let propertyList = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        else { return false }
        return propertyList["CFBundleIdentifier"] as? String == bundleIdentifier
    }

    /// `ditto -x -k`, which restores the app with its signature, extended attributes and symbolic links.
    static func unpack(_ archiveURL: URL, into directoryURL: URL) async throws {
        let terminationStatus = try await run(URL(filePath: "/usr/bin/ditto"), arguments: ["-x", "-k", archiveURL.path, directoryURL.path])
        guard terminationStatus == 0 else { throw InstallationError.unpackingFailed(terminationStatus: terminationStatus) }
    }

    /// Runs `executableURL` and returns its termination status, without blocking a thread while it runs.
    static func run(_ executableURL: URL, arguments: [String]) async throws -> Int32 {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { finishedProcess in
                continuation.resume(returning: finishedProcess.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
    }
}
