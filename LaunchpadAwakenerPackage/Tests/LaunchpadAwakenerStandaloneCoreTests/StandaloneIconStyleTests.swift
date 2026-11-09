import Darwin
import Foundation
@testable import LaunchpadAwakenerStandaloneCore
import Testing

/// The standalone app works the icon style out from SkyLight and IconServices; this asks them on the
/// machine the tests run on, the way the app does.
@Suite("Standalone icon style")
@MainActor
struct StandaloneIconStyleTests {
    init() {
        // The standalone app has IconServices loaded through AppKit's icon drawing; the test process may not.
        _ = dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW)
    }

    /// `SLSIconAppearanceConfiguration` goes through a proxy that checks its getters on the class by name,
    /// so this fails if SkyLight ever hands back an object of another class.
    @Test func iconStyleResolvesOnThisSystem() {
        #expect(SkyLightIconAppearanceConfigurationImplementation.isSupported)
        #expect(StandaloneIconStyle.current != nil)
    }
}
