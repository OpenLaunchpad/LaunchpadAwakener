import CoreGraphics
import Darwin
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import Testing

/// Every icon the springboard shows comes through `IconServicesBridge`, so this renders one the same way,
/// against the IconServices of the machine the tests run on.
///
/// It caught `ISIcon` being a class cluster: `+alloc` hands out an `ISIconFactory`, which is where
/// `initWithURL:` lives, so checking the initialiser on `ISIcon` by name found nothing and every icon came
/// back empty.
@Suite("IconServices bridge")
struct IconServicesBridgeTests {
    init() {
        // The Dock and the standalone app have IconServices loaded already; the test process does not.
        _ = dlopen("/System/Library/PrivateFrameworks/IconServices.framework/IconServices", RTLD_NOW)
    }

    @Test func rendersAnApplicationIcon() throws {
        let descriptor = try #require(IconServicesBridge.makeDescriptor(copying: nil, pointSize: 64, scale: 2))
        let image = try #require(IconServicesBridge.makeIconImage(
            forFileAt: URL(filePath: "/System/Applications/Calculator.app"),
            descriptor: descriptor
        ))

        #expect(image.width >= 128)
        #expect(image.width == image.height)
    }
}
