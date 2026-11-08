@testable import LaunchpadAwakenerPayloadCore
import Testing

/// The name stored after the text input helper's rename field ended: text still composing when the
/// renaming ended comes in late, and only a field the helper really hosted has a say.
@Suite("Renaming through the text input helper")
struct SpringboardRenamingTests {
    @Test("composing text the helper committed on its way out is stored after the name committed first")
    func composingTextComesLate() {
        #expect(SpringboardRenaming.lateTitle(endedString: "测试", committedTitle: "Folder", previousTitle: "Folder", wasHosted: true) == "测试")
    }

    @Test("a field the helper never hosted does not put its own text over what was typed here")
    func unhostedFieldHasNoSay() {
        #expect(SpringboardRenaming.lateTitle(endedString: "Folder", committedTitle: "Games", previousTitle: "Folder", wasHosted: false) == nil)
    }

    @Test("nothing changes when the helper ended with the name committed, or with nothing")
    func nothingNew() {
        #expect(SpringboardRenaming.lateTitle(endedString: "Games", committedTitle: "Games", previousTitle: "Folder", wasHosted: true) == nil)
        #expect(SpringboardRenaming.lateTitle(endedString: "  ", committedTitle: "Games", previousTitle: "Folder", wasHosted: true) == nil)
        #expect(SpringboardRenaming.lateTitle(endedString: "Folder", committedTitle: "", previousTitle: "Folder", wasHosted: true) == nil)
    }
}
