import AppKit
import LaunchpadAwakenerAppCore

extension NSPasteboard.PasteboardType {
    /// One item of the Launchpad layout, dragged within the organizer window: its identifier as text.
    ///
    /// Private to the window, so it is not declared in the Info.plist; nothing outside the app reads it.
    static let organizerItem = NSPasteboard.PasteboardType("com.MxIris.LaunchpadAwakener.organizer-item")
}

/// How dragged layout items travel: one pasteboard item per row, carrying that row's identifier.
///
/// AppKit drags every selected row when the dragged row is selected, and only that row otherwise — the
/// same rule as ``LaunchpadOrganizerViewModel/targetItems(forRow:)`` — so each row writes just itself.
enum OrganizerPasteboard {
    static func pasteboardItem(for itemIdentifier: LaunchpadOrganizer.ItemIdentifier) -> NSPasteboardItem {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(itemIdentifier.description, forType: .organizerItem)
        return pasteboardItem
    }

    /// The layout items a drag carries; empty when it carries none, such as files from the Finder.
    static func draggedItems(in draggingInfo: any NSDraggingInfo) -> Set<LaunchpadOrganizer.ItemIdentifier> {
        let pasteboardItems = draggingInfo.draggingPasteboard.pasteboardItems ?? []
        return Set(pasteboardItems.compactMap { pasteboardItem in
            pasteboardItem.string(forType: .organizerItem).flatMap(Int64.init).map(LaunchpadOrganizer.ItemIdentifier.init(rawValue:))
        })
    }
}
