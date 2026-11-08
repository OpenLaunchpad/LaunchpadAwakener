import ApplicationServices
import Foundation

/// The general pasteboard through the Pasteboard Manager in HIServices, which the Dock already loads;
/// the payload has no AppKit for `NSPasteboard`. Text goes as `public.utf8-plain-text`.
struct SystemPasteboard: SpringboardPasteboard {
    private static let plainTextTypeIdentifier = "public.utf8-plain-text"

    private static func generalPasteboard() -> Pasteboard? {
        var pasteboard: Pasteboard?
        guard PasteboardCreate(kPasteboardClipboard as CFString, &pasteboard) == noErr else { return nil }
        return pasteboard
    }

    func string() -> String? {
        guard let pasteboard = Self.generalPasteboard() else { return nil }
        PasteboardSynchronize(pasteboard)
        var itemCount = 0
        guard PasteboardGetItemCount(pasteboard, &itemCount) == noErr, itemCount > 0 else { return nil }
        // Items are counted from 1.
        var itemIdentifier: PasteboardItemID?
        guard PasteboardGetItemIdentifier(pasteboard, 1, &itemIdentifier) == noErr, let itemIdentifier else { return nil }
        var flavorData: CFData?
        guard
            PasteboardCopyItemFlavorData(pasteboard, itemIdentifier, Self.plainTextTypeIdentifier as CFString, &flavorData) == noErr,
            let flavorData
        else { return nil }
        return String(data: flavorData as Data, encoding: .utf8)
    }

    func setString(_ string: String) {
        guard let pasteboard = Self.generalPasteboard(), PasteboardClear(pasteboard) == noErr else { return }
        PasteboardSynchronize(pasteboard)
        guard let itemIdentifier = PasteboardItemID(bitPattern: 1) else { return }
        PasteboardPutItemFlavor(pasteboard, itemIdentifier, Self.plainTextTypeIdentifier as CFString, Data(string.utf8) as CFData, PasteboardFlavorFlags(rawValue: 0))
    }
}
