import Foundation
import ObjCRuntimeToolbox
@testable import LaunchpadAwakenerStandaloneCore
import Testing

/// What `@RuntimeClassProxy` derives for SkyLight's icon appearance configuration, against the encodings
/// read from SkyLight on 27.2: a getter typed `Int` instead of `UInt32` fails here rather than leaving
/// every icon in the default style.
@Suite("Standalone signatures")
struct StandaloneSignatureTests {
    @Test func iconAppearanceConfiguration() {
        let requirements = SkyLightIconAppearanceConfigurationImplementation.methodRequirements
        let derivedEncodings = Dictionary(
            uniqueKeysWithValues: requirements.map { (NSStringFromSelector($0.selector), $0.typeEncoding) }
        )

        #expect(SkyLightIconAppearanceConfigurationImplementation.runtimeClassName == "SLSIconAppearanceConfiguration")
        #expect(Set(derivedEncodings.keys) == ["iconAppearanceTheme", "appearanceTheme", "iconTintColorName"])
        for (selectorName, derivedEncoding) in derivedEncodings {
            #expect(ObjCTypeEncodingNormalization.matches(derivedEncoding, "I16@0:8"), "\(selectorName): derived \(derivedEncoding)")
        }
    }
}
