import Foundation
import OSToolbox

/// Builds the bundle whose icon the payload puts on the Dock's Apps tile.
///
/// ## Why there has to be a bundle at all
///
/// The payload renders the icon through IconServices, because that is the only thing that renders the
/// light, dark and tinted appearances macOS 26 and 27 keep as layered resources in an app's asset
/// catalog — a compiled `.icns` holds one appearance and would strand the Apps tile in the light one.
/// IconServices renders those from a *bundle*, so there has to be one whose icon is the Launchpad icon
/// without the gear this configuration app's own icon carries.
///
/// ## Why it is assembled here and not shipped inside the app
///
/// A `.app` inside this app's resources is nested code: LaunchServices registers it, so a second
/// "Launchpad" would show up in places the user looks, and every signing and notarisation step would have
/// to carry it. The same reasoning already keeps the standalone app in this app's resources as a zip.
///
/// So the app's resources carry the icon's *parts* as ordinary files, and this assembles them into a
/// bundle under Application Support, where nothing registers it. Two things make that bundle work:
///
/// - **The directory must end in `.app`.** A `.bundle` of the same contents renders a folder icon:
///   IconServices does not look in its asset catalog.
/// - **`CFBundleExecutable` must name something that can actually run.** Without it — or with a file that
///   is not executable — IconServices renders the icon with the "cannot be opened" slash across it, which
///   is what the Dock would then show. A shell script is enough, and it is nothing but `exit 0`; this
///   bundle exists to be looked at, never to be opened.
///
/// Both were found by rendering each form and comparing the result; `DockAppsIconHostTests` keeps them
/// honest.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockAppsIconHost")
public enum DockAppsIconHost {
    /// The folder in this app's resources holding the icon's parts, put there by the "Embed Standalone
    /// Launchpad" build phase from the standalone app's own build product.
    public static let bundledResourcesName = "LaunchpadDockIcon"

    /// What the assembled bundle is called, and the name of the script inside it.
    public static let hostBundleName = "LaunchpadDockIcon"

    static let hostBundleIdentifier = "com.MxIris.LaunchpadAwakener.DockIcon"

    /// The asset catalog is what carries the three appearances; the `.icns` is what older paths read.
    static let resourceNames = ["Assets.car", "AppIcon.icns"]

    /// Nothing but `exit 0`: IconServices only needs the executable to be runnable, and no one runs this.
    private static let executableContents = "#!/bin/sh\nexit 0\n"

    /// The assembled bundle, building or rebuilding it when it is missing or out of date.
    ///
    /// Rebuilding is keyed on the asset catalog's size and modification date, so a new build of the app —
    /// which is how the icon changes — produces a new bundle, and an unchanged app does no file work
    /// beyond two `stat`s.
    public static func prepare(
        copyingResourcesFrom sourceDirectory: URL? = nil,
        into applicationSupportDirectory: URL = defaultApplicationSupportDirectory
    ) throws -> URL {
        let sourceDirectory = try sourceDirectory ?? bundledResourcesDirectory()
        let hostBundleURL = applicationSupportDirectory
            .appendingPathComponent("\(hostBundleName).app", isDirectory: true)

        if isUpToDate(hostBundleURL: hostBundleURL, sourceDirectory: sourceDirectory) {
            return hostBundleURL
        }

        try assemble(at: hostBundleURL, from: sourceDirectory)
        #log(.default, "Assembled the Dock's Apps icon at \(hostBundleURL.path, privacy: .public)")
        return hostBundleURL
    }

    /// Where this app's own build keeps the icon's parts.
    private static func bundledResourcesDirectory() throws -> URL {
        guard let sourceDirectory = Bundle.main.url(forResource: bundledResourcesName, withExtension: nil) else {
            throw Failure.missingResources
        }
        return sourceDirectory
    }

    /// `~/Library/Application Support/LaunchpadAwakener`, where this app's other per-user state lives.
    public static var defaultApplicationSupportDirectory: URL {
        let libraryDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return libraryDirectory.appendingPathComponent("LaunchpadAwakener", isDirectory: true)
    }

    // MARK: - Building it

    private static func isUpToDate(hostBundleURL: URL, sourceDirectory: URL) -> Bool {
        let resourcesURL = hostBundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        guard FileManager.default.isExecutableFile(
            atPath: hostBundleURL.appendingPathComponent("Contents/MacOS/\(hostBundleName)").path
        ) else { return false }
        return resourceNames.allSatisfy { resourceName in
            let source = fileSignature(at: sourceDirectory.appendingPathComponent(resourceName))
            let assembled = fileSignature(at: resourcesURL.appendingPathComponent(resourceName))
            return source != nil && source == assembled
        }
    }

    /// Size and modification date, the pair that changes when a build replaces the file.
    private static func fileSignature(at url: URL) -> [Int]? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
        guard let size = attributes[.size] as? Int else { return nil }
        let modifiedAt = (attributes[.modificationDate] as? Date).map { Int($0.timeIntervalSince1970) } ?? 0
        return [size, modifiedAt]
    }

    private static func assemble(at hostBundleURL: URL, from sourceDirectory: URL) throws {
        let fileManager = FileManager.default
        // Built beside the destination and moved into place, so a bundle that is being read is never a
        // half-written one.
        let stagingURL = hostBundleURL.deletingLastPathComponent()
            .appendingPathComponent("\(hostBundleName)-staging-\(UUID().uuidString).app", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingURL) }

        let contentsURL = stagingURL.appendingPathComponent("Contents", isDirectory: true)
        let resourcesURL = contentsURL.appendingPathComponent("Resources", isDirectory: true)
        let macOSURL = contentsURL.appendingPathComponent("MacOS", isDirectory: true)
        try fileManager.createDirectory(at: resourcesURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: macOSURL, withIntermediateDirectories: true)

        for resourceName in resourceNames {
            let source = sourceDirectory.appendingPathComponent(resourceName)
            guard fileManager.fileExists(atPath: source.path) else { throw Failure.missingResource(resourceName) }
            // Copied rather than linked: a symbolic link out of this bundle and into the app would break
            // the moment the app is moved or replaced, and the icon would silently go back to the Dock's.
            try fileManager.copyItem(at: source, to: resourcesURL.appendingPathComponent(resourceName))
            // The source's modification date comes along, which is what `isUpToDate(…)` compares.
            try? fileManager.setAttributes(
                [.modificationDate: fileModificationDate(at: source) ?? Date()],
                ofItemAtPath: resourcesURL.appendingPathComponent(resourceName).path
            )
        }

        let executableURL = macOSURL.appendingPathComponent(hostBundleName)
        try Data(executableContents.utf8).write(to: executableURL)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

        let information: [String: Any] = [
            "CFBundleIdentifier": hostBundleIdentifier,
            "CFBundleName": "Launchpad",
            "CFBundlePackageType": "APPL",
            "CFBundleExecutable": hostBundleName,
            // Both names: the asset catalog carries the three appearances, the `.icns` is the fallback.
            "CFBundleIconName": "AppIcon",
            "CFBundleIconFile": "AppIcon",
            // Should anything ever register this bundle, it stays out of the Dock and the switcher.
            "LSUIElement": true,
        ]
        let propertyList = try PropertyListSerialization.data(fromPropertyList: information, format: .xml, options: 0)
        try propertyList.write(to: contentsURL.appendingPathComponent("Info.plist"))

        try fileManager.createDirectory(
            at: hostBundleURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if fileManager.fileExists(atPath: hostBundleURL.path) {
            try fileManager.removeItem(at: hostBundleURL)
        }
        try fileManager.moveItem(at: stagingURL, to: hostBundleURL)
    }

    private static func fileModificationDate(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public enum Failure: Error, Equatable {
        /// This build's resources do not carry the icon at all.
        case missingResources
        case missingResource(String)

        public var errorDescription: String {
            switch self {
            case .missingResources:
                "This build does not carry the Launchpad icon."
            case .missingResource(let name):
                "This build's Launchpad icon is missing \(name)."
            }
        }
    }
}
