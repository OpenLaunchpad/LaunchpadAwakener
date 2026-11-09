import CoreGraphics
import Darwin
import Foundation
import LaunchpadAwakenerPrivateInterfaces
@testable import LaunchpadAwakenerStandaloneCore
import Testing

/// The standalone app works the icon style out from SkyLight, IconServices and IconFoundation, calling
/// their private classes directly as `LaunchpadAwakenerPrivateInterfaces` declares them. Nothing checks those
/// declarations at run time, so these call them on the machine the tests run on: a declaration that no
/// longer matches the system fails here, or crashes the test process, instead of the app.
@Suite("Standalone icon style")
@MainActor
struct StandaloneIconStyleTests {
    init() {
        // The standalone app has IconServices loaded through AppKit's icon drawing; the test process may not.
        _ = dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW)
    }

    @Test func iconStyleResolvesOnThisSystem() {
        #expect(StandaloneIconStyle.current != nil)
    }

    /// The tinted styles, which the machine's own icon appearance rarely exercises.
    @Test func tintColorsComeFromIconFoundation() throws {
        let systemColor = try #require(IFColor(systemColor: 7, appearance: 1, contrast: 0, vibrancy: 0))
        let customColor = try #require(IFColor(cgColor: CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1)))
        let descriptor = ISImageDescriptor()

        descriptor.tintColor = systemColor
        #expect(descriptor.tintColor === systemColor)
        descriptor.tintColor = customColor
        #expect(descriptor.tintColor === customColor)
    }

    @Test func skyLightHasAnIconAppearanceConfiguration() throws {
        let configuration = try #require(SLSIconAppearanceConfiguration.fetchCurrentIconAppearanceConfiguration())

        #expect(configuration.iconAppearanceTheme <= 8)
        #expect(configuration.iconTintColorName <= 10)
    }
}
