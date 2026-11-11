import Foundation
import ObjCRuntimeToolbox
@testable import LaunchpadAwakenerPayloadCore
import Testing

// The macros derive each selector and type encoding from a Swift declaration; these pin what they
// derive to the encodings read from the 27.2 Dock's Objective-C metadata, the same from 26.0 to 27.2.
// A Swift type that encodes differently — `CGFloat` for a `float`, `Int` for an `unsigned int` — fails
// here on the development machine instead of switching the payload off inside the Dock.

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

/// The selectors `requirements` name and the encodings derived for them, against the ones read from the Dock.
/// A class method's selector is recorded with a leading `+`.
private func expectRequirements(
    _ requirements: [RuntimeClassProxySupport.MethodRequirement],
    toMatch recordedEncodings: [String: String],
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let methodNames = requirements.map { requirement in
        (requirement.isInstanceMethod ? "" : "+") + NSStringFromSelector(requirement.selector)
    }
    #expect(Set(methodNames) == Set(recordedEncodings.keys), sourceLocation: sourceLocation)
    for (methodName, requirement) in zip(methodNames, requirements) {
        let recordedEncoding = recordedEncodings[methodName] ?? "none"
        #expect(
            ObjCTypeEncodingNormalization.matches(requirement.typeEncoding, recordedEncoding),
            "\(methodName): derived \(requirement.typeEncoding), the Dock has \(recordedEncoding)",
            sourceLocation: sourceLocation
        )
    }
}

@Suite("Proxy signatures")
struct DockProxySignatureTests {
    @Test func layerKitWindow() {
        #expect(DockLayerKitWindowImplementation.runtimeClassName == "WALayerKitWindow")
        expectRequirements(DockLayerKitWindowImplementation.methodRequirements, toMatch: [
            "initWithFrame:connection:display:tags:level:": "@68@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16I48I52Q56i64",
            "layer": "@16@0:8",
            "wid": "I16@0:8",
            "order:otherWindow:": "v24@0:8i16I20",
        ])
    }

    @Test func dockBar() {
        #expect(DockBarGeometryImplementation.runtimeClassName == "DockBar")
        expectRequirements(DockBarGeometryImplementation.methodRequirements, toMatch: [
            "rect": "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8",
            "display": "@16@0:8",
            "environment": "@16@0:8",
            "desiredTileSize": "f16@0:8",
            "tileSize": "f16@0:8",
        ])
        #expect(DockBarVisibilityAccessImplementation.runtimeClassName == "DockBar")
        expectRequirements(DockBarVisibilityAccessImplementation.methodRequirements, toMatch: [
            "visibilityController": "@16@0:8",
        ])
    }

    @Test func displayDescriptor() {
        #expect(DockDisplayDescriptorImplementation.runtimeClassName == "DisplayDescriptor")
        expectRequirements(DockDisplayDescriptorImplementation.methodRequirements, toMatch: [
            "notchBounds": "{CGRect={CGPoint=dd}{CGSize=dd}}16@0:8",
        ])
        // Checked on first use rather than before the hooks: without it only the choice of display goes.
        #expect(DockDisplayIdentityImplementation.runtimeClassName == "DisplayDescriptor")
        expectRequirements(DockDisplayIdentityImplementation.methodRequirements, toMatch: [
            "identifier": "I16@0:8",
        ])
    }

    @Test func visibilityController() {
        #expect(DockVisibilityControllerImplementation.runtimeClassName == "DockVisibility")
        expectRequirements(DockVisibilityControllerImplementation.methodRequirements, toMatch: [
            "setOverrideShowType:": "v24@0:8Q16",
            "removeOverrideShowType:": "v24@0:8Q16",
            "forceDockHiddenWithReason:": "v24@0:8@16",
            "removeForceDockHiddenWithReason:": "v24@0:8@16",
        ])
    }

    @Test func layerClasses() {
        #expect(DockGridLayerImplementation.runtimeClassName == "ECGridLayer")
        expectRequirements(DockGridLayerImplementation.methodRequirements, toMatch: [
            "initWithLayerSource:rows:columns:scaleFactor:layoutRTL:": "@48@0:8@16q24q32f40B44",
            "layout": "v16@0:8",
        ])
        #expect(DockImageGridLayerImplementation.runtimeClassName == "ECImageGridLayer")
        expectRequirements(DockImageGridLayerImplementation.methodRequirements, toMatch: [
            "initWithLayerSource:rows:columns:spacing:scaleFactor:layoutRTL:": "@56@0:8@16q24q32Q40f48B52",
            "layout": "v16@0:8",
            "layerSourceInvalidated:": "v24@0:8@16",
            "scrollToAvailableSpace": "v16@0:8",
            "scrollToTop": "v16@0:8",
        ])
        #expect(DockShadowTextLayerImplementation.runtimeClassName == "ECShadowTextLayer")
        expectRequirements(DockShadowTextLayerImplementation.methodRequirements, toMatch: [
            "init": "@16@0:8",
            "setTextShadowColor:": "v24@0:8@16",
            "setTextShadowOffset:": "v32@0:8{CGSize=dd}16",
            "setTextShadowBlur:": "v24@0:8d16",
        ])
        #expect(DockTextLayerImplementation.runtimeClassName == "ECTextLayer")
        expectRequirements(DockTextLayerImplementation.methodRequirements, toMatch: [
            "init": "@16@0:8",
        ])
        #expect(DockLayerMaterialImplementation.runtimeClassName == "CALayer")
        expectRequirements(DockLayerMaterialImplementation.methodRequirements, toMatch: [
            "setMaterialControl:appearance:": "v32@0:8Q16Q24",
        ])
    }

    @Test func glass() {
        #expect(DockGlassMaterialLayerControllerImplementation.runtimeClassName == "DockGlassMaterialLayerController")
        expectRequirements(DockGlassMaterialLayerControllerImplementation.methodRequirements, toMatch: [
            "initWithVariant:adaptive:": "@28@0:8q16B24",
            "+currentDockMaterialEnvironmentWithColorScheme:": "@24@0:8q16",
            "rootLayer": "@16@0:8",
            "updateUsingLayoutConfiguration:environment:": "v32@0:8@16@24",
        ])
        #expect(DockGlassMaterialLayoutConfigurationImplementation.runtimeClassName == "DockGlassMaterialLayoutConfiguration")
        expectRequirements(DockGlassMaterialLayoutConfigurationImplementation.methodRequirements, toMatch: [
            "setFrame:": "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16",
            "setElements:": "v24@0:8@16",
        ])
        #expect(DockSignedDistanceFieldElementImplementation.runtimeClassName == "DockSDFElement")
        expectRequirements(DockSignedDistanceFieldElementImplementation.methodRequirements, toMatch: [
            "setUntransformedFrame:": "v48@0:8{CGRect={CGPoint=dd}{CGSize=dd}}16",
            "setCornerRadius:": "v24@0:8d16",
        ])
        #expect(DockGlassMaterialEnvironmentImplementation.runtimeClassName == "DockGlassMaterialEnvironment")
        expectRequirements(DockGlassMaterialEnvironmentImplementation.methodRequirements, toMatch: [
            "setBackdropGroupName:": "v24@0:8@16",
            "setDisplayScale:": "v24@0:8d16",
        ])
    }

    /// What the environment hands out, checked on each object's own class when it is reached.
    @Test func reachedThroughTheEnvironment() {
        expectRequirements(DockEnvironmentIconAppearanceAccessImplementation.methodRequirements, toMatch: [
            "iconAppearanceMonitor": "@16@0:8",
        ])
        expectRequirements(DockIconAppearanceMonitorImplementation.methodRequirements, toMatch: [
            "appearance": "@16@0:8",
        ])
        expectRequirements(DockIconAppearanceImplementation.methodRequirements, toMatch: [
            "iconDescription": "@16@0:8",
            "style": "C16@0:8",
        ])
        expectRequirements(DockEnvironmentUninstallerAccessImplementation.methodRequirements, toMatch: [
            "applicationUninstaller": "@16@0:8",
        ])
        expectRequirements(DockApplicationUninstallingImplementation.methodRequirements, toMatch: [
            "uninstallabilityOfFileAtURL:": "i24@0:8@16",
            "uninstallBundleAtURL:handler:": "v32@0:8@16@?24",
        ])
    }

    /// The methods checked before any hook goes in: the 23 the replica calls, each recorded once, so the
    /// log's `Checked 23 Dock method(s)` keeps meaning what the implementation note says it means.
    @Test func requiredMethodsAreTheOnesTheReplicaCalls() {
        let names = DockHostInterface.requiredMethods.map { "\($0.className) \($0.selectorName)" }

        #expect(names.count == 23)
        #expect(Set(names) == [
            "WALayerKitWindow initWithFrame:connection:display:tags:level:",
            "WALayerKitWindow layer",
            "WALayerKitWindow wid",
            "WALayerKitWindow order:otherWindow:",
            "DockBar rect",
            "DockBar display",
            "DockBar environment",
            "DockBar desiredTileSize",
            "DockBar tileSize",
            "DisplayDescriptor notchBounds",
            "ECGridLayer initWithLayerSource:rows:columns:scaleFactor:layoutRTL:",
            "ECGridLayer layout",
            "ECShadowTextLayer init",
            "ECShadowTextLayer setTextShadowColor:",
            "ECShadowTextLayer setTextShadowOffset:",
            "ECShadowTextLayer setTextShadowBlur:",
            "ECTextLayer init",
            "CALayer setMaterialControl:appearance:",
            "ECImageGridLayer initWithLayerSource:rows:columns:spacing:scaleFactor:layoutRTL:",
            "ECImageGridLayer layout",
            "ECImageGridLayer layerSourceInvalidated:",
            "ECImageGridLayer scrollToAvailableSpace",
            "ECImageGridLayer scrollToTop",
        ])
    }
}
