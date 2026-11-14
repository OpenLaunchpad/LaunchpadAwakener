import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerAppCore
import LaunchpadAwakenerPrivateInterfaces
@testable import LaunchpadAwakenerSpringboardCore
import Testing

/// Whether this process has a window server session.
///
/// The "cannot be opened" decoration is LaunchServices', and it is only drawn where there is a graphical
/// session: on GitHub's headless runners the same bundle renders without it. So the test that depends on
/// it runs on a Mac someone is logged into — a development machine or a test machine — and is skipped in
/// CI, rather than being written to pass everywhere and therefore prove less.
private let hasWindowServerSession = CGSessionCopyCurrentDictionary() != nil

/// The bundle the payload renders the Dock's Apps icon from.
///
/// Two of these tests are the reason this bundle exists in the form it does, and both were found by
/// rendering a form and looking at what came back:
///
/// - An icon rendered from a bundle follows the light, dark and tinted appearances. A compiled `.icns`,
///   which is what this used to hand the Dock, holds one appearance and leaves the Apps tile light while
///   the Dock around it goes dark.
/// - A bundle whose `CFBundleExecutable` cannot be run is rendered with the "cannot be opened" slash
///   across it. Nothing in the code makes that visible — the icon simply comes back wrong — so it is
///   checked here against the same bundle with the executable bit taken off. That check needs a window
///   server session and is skipped where there is none; that the assembled executable *is* executable is
///   checked unconditionally in `assemblesABundle`.
///
/// The icon's own resources come from a system app rather than this project's build products, so the
/// tests say nothing about where anybody's build output happens to be.
@Suite("The icon bundle the Dock's Apps tile is rendered from")
struct DockAppsIconHostTests {
    init() {
        // The Dock and this app have IconServices loaded already; the test process does not.
        _ = dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW)
    }

    /// A system app with the layered icon resources macOS 26 and 27 render the three appearances from.
    private static let resourceDonorPath = "/System/Applications/Calculator.app"

    // MARK: - What it builds

    @Test("the assembled bundle has everything IconServices needs")
    func assemblesABundle() throws {
        let locations = try TemporaryLocations()
        let hostBundleURL = try DockAppsIconHost.prepare(
            copyingResourcesFrom: locations.sourceDirectory,
            into: locations.applicationSupportDirectory
        )

        #expect(hostBundleURL.pathExtension == "app", "a .bundle of the same contents renders a folder icon")
        #expect(FileManager.default.isExecutableFile(atPath: locations.executablePath(in: hostBundleURL)))
        for resourceName in DockAppsIconHost.resourceNames {
            let resourceURL = hostBundleURL.appendingPathComponent("Contents/Resources/\(resourceName)")
            #expect(FileManager.default.fileExists(atPath: resourceURL.path), "\(resourceName) is missing")
        }

        let informationURL = hostBundleURL.appendingPathComponent("Contents/Info.plist")
        let information = try #require(NSDictionary(contentsOf: informationURL) as? [String: Any])
        #expect(information["CFBundleIconName"] as? String == "AppIcon")
        #expect(information["CFBundleExecutable"] as? String == DockAppsIconHost.hostBundleName)
    }

    @Test("a second run of the same build does not build it again")
    func leavesAnUpToDateBundleAlone() throws {
        let locations = try TemporaryLocations()
        let hostBundleURL = try DockAppsIconHost.prepare(
            copyingResourcesFrom: locations.sourceDirectory,
            into: locations.applicationSupportDirectory
        )
        let markerURL = hostBundleURL.appendingPathComponent("Contents/Resources/marker")
        try Data("still here".utf8).write(to: markerURL)

        _ = try DockAppsIconHost.prepare(
            copyingResourcesFrom: locations.sourceDirectory,
            into: locations.applicationSupportDirectory
        )

        #expect(FileManager.default.fileExists(atPath: markerURL.path), "the bundle was rebuilt for nothing")
    }

    @Test("a new build of the app rebuilds it")
    func rebuildsWhenTheIconChanges() throws {
        let locations = try TemporaryLocations()
        let hostBundleURL = try DockAppsIconHost.prepare(
            copyingResourcesFrom: locations.sourceDirectory,
            into: locations.applicationSupportDirectory
        )
        let markerURL = hostBundleURL.appendingPathComponent("Contents/Resources/marker")
        try Data("should go".utf8).write(to: markerURL)

        // What a new build of the app looks like from here: the same resource, different bytes.
        let assetCatalogURL = locations.sourceDirectory.appendingPathComponent("Assets.car")
        var assetCatalog = try Data(contentsOf: assetCatalogURL)
        assetCatalog.append(contentsOf: [0])
        try assetCatalog.write(to: assetCatalogURL)

        _ = try DockAppsIconHost.prepare(
            copyingResourcesFrom: locations.sourceDirectory,
            into: locations.applicationSupportDirectory
        )

        #expect(!FileManager.default.fileExists(atPath: markerURL.path), "the new icon did not replace the old")
    }

    @Test("resources that are not there are reported, not half-built around")
    func reportsMissingResources() throws {
        let locations = try TemporaryLocations()
        try FileManager.default.removeItem(at: locations.sourceDirectory.appendingPathComponent("Assets.car"))

        #expect(throws: DockAppsIconHost.Failure.missingResource("Assets.car")) {
            try DockAppsIconHost.prepare(
                copyingResourcesFrom: locations.sourceDirectory,
                into: locations.applicationSupportDirectory
            )
        }
    }

    // MARK: - What IconServices makes of it

    @Test("the icon follows the appearance, which an .icns could not")
    func followsTheAppearance() throws {
        let locations = try TemporaryLocations()
        let hostBundleURL = try DockAppsIconHost.prepare(
            copyingResourcesFrom: locations.sourceDirectory,
            into: locations.applicationSupportDirectory
        )

        let light = try #require(Self.renderedBytes(ofBundleAt: hostBundleURL, appearance: 0))
        let dark = try #require(Self.renderedBytes(ofBundleAt: hostBundleURL, appearance: 1))

        #expect(light != dark, "the dark appearance came back identical to the light one")
    }

    @Test(
        "an executable that cannot run puts the cannot-open slash across the icon",
        .enabled(if: hasWindowServerSession, "needs a window server session; see hasWindowServerSession")
    )
    func needsARunnableExecutable() throws {
        let runnable = try TemporaryLocations()
        let hostBundleURL = try DockAppsIconHost.prepare(
            copyingResourcesFrom: runnable.sourceDirectory,
            into: runnable.applicationSupportDirectory
        )

        // The same bundle, built the same way, with only the executable bit taken off. A separate
        // directory, because IconServices caches what it has rendered for a path.
        let crippled = try TemporaryLocations()
        let crippledBundleURL = try DockAppsIconHost.prepare(
            copyingResourcesFrom: crippled.sourceDirectory,
            into: crippled.applicationSupportDirectory
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o644],
            ofItemAtPath: crippled.executablePath(in: crippledBundleURL)
        )

        let asBuilt = try #require(Self.renderedBytes(ofBundleAt: hostBundleURL, appearance: 0))
        let withoutARunnableExecutable = Self.renderedBytes(ofBundleAt: crippledBundleURL, appearance: 0)

        #expect(
            asBuilt != withoutARunnableExecutable,
            "both rendered the same, so the executable is no longer what keeps the slash off the icon"
        )
    }

    // MARK: - Support

    /// A source directory holding a real app's icon resources, and an empty Application Support of its
    /// own. Both go away with the temporary directory.
    private struct TemporaryLocations {
        let sourceDirectory: URL
        let applicationSupportDirectory: URL

        init() throws {
            let root = URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("DockAppsIconHostTests-\(UUID().uuidString)", isDirectory: true)
            sourceDirectory = root.appendingPathComponent("Resources", isDirectory: true)
            applicationSupportDirectory = root.appendingPathComponent("ApplicationSupport", isDirectory: true)
            try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: applicationSupportDirectory,
                withIntermediateDirectories: true
            )

            let donorResources = URL(fileURLWithPath: DockAppsIconHostTests.resourceDonorPath)
                .appendingPathComponent("Contents/Resources", isDirectory: true)
            for resourceName in DockAppsIconHost.resourceNames {
                let source = donorResources.appendingPathComponent(resourceName)
                guard FileManager.default.fileExists(atPath: source.path) else { continue }
                try FileManager.default.copyItem(
                    at: source,
                    to: sourceDirectory.appendingPathComponent(resourceName)
                )
            }
        }

        func executablePath(in hostBundleURL: URL) -> String {
            hostBundleURL
                .appendingPathComponent("Contents/MacOS/\(DockAppsIconHost.hostBundleName)")
                .path
        }
    }

    /// Renders the bundle's icon the way the payload does, and flattens it so two renderings compare.
    private static func renderedBytes(ofBundleAt hostBundleURL: URL, appearance: Int) -> Data? {
        let descriptor = ISImageDescriptor()
        descriptor.size = CGSize(width: 128, height: 128)
        descriptor.scale = 2
        descriptor.appearance = appearance
        descriptor.appearanceVariant = 0
        guard let image = IconServicesBridge.makeIconImage(forFileAt: hostBundleURL, descriptor: descriptor) else {
            return nil
        }

        let side = 256
        var pixels = Data(count: side * side * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: side * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        return didDraw ? pixels : nil
    }
}
