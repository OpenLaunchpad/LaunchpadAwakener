import Foundation
import ObjCRuntimeToolbox
@testable import LaunchpadAwakenerPayloadCore
import Testing

/// The macros derive each selector and type encoding from a Swift declaration; these pin what they
/// derive to the encodings read from the 27.2 Dock's Objective-C metadata, the same from 26.0 to 27.2.
/// A Swift type that encodes differently — `CGFloat` for a `float`, `Int` for an `unsigned int` — fails
/// here on the development machine instead of switching the payload off inside the Dock.
@Suite("Hook signatures")
struct PayloadHookSignatureTests {
    @Test func spotlightHookMatchesTheDock() throws {
        let descriptor = try #require(SpotlightHooks.descriptors().first)

        #expect(SpotlightHooks.descriptors().count == 1)
        #expect(descriptor.className == "Spotlight")
        #expect(NSStringFromSelector(descriptor.selector) == "sendLaunchAppsBrowsing")
        #expect(descriptor.isInstanceMethod)
        #expect(ObjCTypeEncodingNormalization.matches(descriptor.expectedTypeEncoding, "v16@0:8"))
    }

    @Test func eventHandlerHookMatchesTheDock() throws {
        let descriptor = try #require(DockAppEventHandlerHooks.descriptors().first)

        #expect(DockAppEventHandlerHooks.descriptors().count == 1)
        #expect(descriptor.className == "DockAppEventHandler")
        #expect(NSStringFromSelector(descriptor.selector) == "handleDockBarEvent:type:")
        #expect(descriptor.isInstanceMethod)
        #expect(ObjCTypeEncodingNormalization.matches(descriptor.expectedTypeEncoding, "v24@0:8@16I20"))
    }
}
