import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import Testing

/// macOS 15's own resources — the search field's images, the springboard's words and "Untitled" — come
/// from the Dock's bundle, which still carries them on 26 and 27. Inside the Dock that is its main bundle;
/// the standalone app reads the system's Dock.app, so these read it the same way.
@Suite("Resources from the Dock's bundle")
struct SpringboardResourceTests {
    private static let dockBundle = Bundle(url: URL(filePath: "/System/Library/CoreServices/Dock.app", directoryHint: .isDirectory))

    @Test("the search field's images are in the Dock's bundle, at both scales", arguments: ["ectl_search_background", "ectl_search_loupe", "ectl_search_close", "ecsb_closebox"])
    func searchFieldImagesLoad(imageName: String) throws {
        let dockBundle = try #require(Self.dockBundle)
        let retinaImage = try #require(SpringboardTextures.image(named: imageName, scale: 2, in: dockBundle))
        let plainImage = try #require(SpringboardTextures.image(named: imageName, scale: 1, in: dockBundle))
        #expect(retinaImage.width == plainImage.width * 2)
    }

    @Test("an image the bundle does not have is nil, not a crash")
    func missingImageIsNil() throws {
        let dockBundle = try #require(Self.dockBundle)
        #expect(SpringboardTextures.image(named: "no_such_image", scale: 2, in: dockBundle) == nil)
    }

    @Test(
        "the words follow the first language 15 had them in, a region falling back to its language",
        arguments: [
            (["zh_CN"], "搜索"),
            (["zh-HK"], "搜尋"),
            (["pt-BR", "en"], "Buscar"),
            (["de_AT"], "Suchen"),
            (["kk", "fr_CA"], "Rechercher"),
            (["kk"], "Search"),
            ([], "Search"),
        ]
    )
    func wordsFollowTheLanguage(localizations: [String], expectedSearch: String) {
        #expect(SpringboardStrings.translation(forLocalizations: localizations).search == expectedSearch)
    }

    @Test(
        "the Dock's language is picked from its own list for the user, whatever the main bundle speaks",
        arguments: [(["zh-Hans-CN"], "zh_CN"), (["zh-Hant-TW"], "zh_TW"), (["de-AT", "en"], "de"), (["en-US"], "en")]
    )
    func dockLanguageForUser(preferences: [String], expectedLocalization: String) throws {
        let dockBundle = try #require(Self.dockBundle)
        #expect(SpringboardLocalization.preferredLocalizations(of: dockBundle, forPreferences: preferences).first == expectedLocalization)
    }

    @Test("a new folder without a category is \"Untitled\" from the Dock's own strings, in English without them")
    @MainActor
    func untitledFolderName() throws {
        #expect(SpringboardInterface.untitledFolderName(in: nil) == "Untitled")
        let dockBundle = try #require(Self.dockBundle)
        #expect(SpringboardInterface.untitledFolderName(in: dockBundle, forPreferences: ["zh-Hans-CN"]) == "未命名")
        #expect(SpringboardInterface.untitledFolderName(in: dockBundle, forPreferences: ["en-US"]) == "Untitled")
    }
}
