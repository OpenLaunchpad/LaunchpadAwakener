import AppKit
import LaunchpadAwakenerShared

/// The text input helper's application. It hosts one text field for the springboard in the Dock, in a
/// window that never goes on screen, the way macOS 15's `com.apple.dock.ecti` service did.
public final class TextInputApplication: NSApplication {
    // The ecti service's `ECTIHelperApp` answered both with 0. AppKit then takes the window that never goes
    // on screen for the key window and this process for the active application, which input methods need;
    // the Dock keeps the real key focus throughout and forwards the keys.
    @objc(_stealKeyFocusWithOptions:)
    func stealKeyFocus(withOptions options: UInt32) -> Int32 {
        0
    }

    @objc(_releaseKeyFocus)
    func releaseKeyFocus() -> Int32 {
        0
    }

    /// Runs the helper until it is terminated.
    @MainActor
    public static func runHelper() {
        // The first use of `shared` on this class makes the application an instance of it.
        let application = TextInputApplication.shared
        application.setActivationPolicy(.accessory)
        application.mainMenu = makeMainMenu()
        TextInputService.shared.start()
        application.run()
    }

    /// An Edit menu, for the field's key equivalents: undo, cut, copy, paste and select all. The ecti
    /// service had one in its main nib.
    @MainActor
    private static func makeMainMenu() -> NSMenu {
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redoItem = editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = editMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(NSMenuItem())
        mainMenu.addItem(editItem)
        return mainMenu
    }
}
