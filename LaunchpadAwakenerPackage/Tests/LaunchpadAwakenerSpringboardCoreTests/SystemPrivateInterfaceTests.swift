import CoreGraphics
import Darwin
import Foundation
import LaunchpadAwakenerPrivateInterfaces
@testable import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// The private classes of IconServices and QuartzCore the springboard calls directly, as
/// `LaunchpadAwakenerPrivateInterfaces` declares them. Nothing checks those declarations at run time, so these
/// call them on the machine the tests run on: one that no longer matches the system fails here, or
/// crashes the test process, instead of the Dock.
@Suite("System private interfaces")
struct SystemPrivateInterfaceTests {
    init() {
        // The Dock and the standalone app have IconServices loaded already; the test process does not.
        _ = dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW)
    }

    /// Every icon the springboard shows comes through `IconServicesBridge`. This also caught `ISIcon` being
    /// a class cluster: `+alloc` hands out an `ISIconFactory`, which is where `initWithURL:` lives.
    @Test func rendersAnApplicationIcon() throws {
        let descriptor = try #require(IconServicesBridge.makeDescriptor(copying: nil, pointSize: 64, scale: 2))
        let image = try #require(IconServicesBridge.makeIconImage(
            forFileAt: URL(filePath: "/System/Applications/Calculator.app"),
            descriptor: descriptor
        ))

        #expect(image.width >= 128)
        #expect(image.width == image.height)
    }

    @Test func makesTheDesktopFilters() throws {
        let filters = try #require(QuartzCorePrivate.desktopBackgroundFilters())

        #expect(filters.count == 3)
    }

    @Test func layerHostKeepsItsContext() {
        let layerHost = CALayerHost()

        layerHost.contextId = 42

        #expect(layerHost.contextId == 42)
    }
}
