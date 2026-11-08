import CoreServices
import Foundation

/// Which applications macOS 15 showed with a blue dot: downloaded from the App Store, not launched since.
///
/// macOS 15 set the mark when its App Store download finished (`-[Springboard _processCompleteStoreItems]`,
/// 15.5 `0x100096D08`) and cleared it when the Dock heard of the application's launch. macOS 27's Dock
/// tells nothing of either to code outside its Swift internals, so the mark goes on an application that
/// appears with a purchase receipt, and comes off once LaunchServices has recorded a use of it newer than
/// the copy.
package enum RecentlyAddedApplications {
    /// The marked applications among `applications` that `hasBeenLaunched` says were launched; only
    /// those are asked about.
    package static func launchedBundleIdentifiers(among applications: [LaunchpadApplication], hasBeenLaunched: (URL) -> Bool) -> Set<String> {
        Set(applications.filter { application in
            guard application.isRecentlyAdded, let bundleURL = application.bundleURL else { return false }
            return hasBeenLaunched(bundleURL)
        }.map(\.bundleIdentifier))
    }

    /// Whether the bundle carries the receipt of an App Store purchase.
    package static func isFromAppStore(applicationAt bundleURL: URL) -> Bool {
        FileManager.default.fileExists(atPath: bundleURL.appendingPathComponent("Contents/_MASReceipt/receipt").path)
    }

    /// Whether the application at `bundleURL` has been launched since it was put there, by the dates
    /// Spotlight keeps for it.
    package static func hasBeenLaunched(applicationAt bundleURL: URL) -> Bool {
        guard let metadataItem = MDItemCreateWithURL(kCFAllocatorDefault, bundleURL as CFURL) else { return false }
        func date(_ attribute: CFString) -> Date? {
            MDItemCopyAttribute(metadataItem, attribute) as? Date
        }
        return hasBeenLaunched(lastUsedDate: date(kMDItemLastUsedDate), dateAdded: date(kMDItemDateAdded))
    }

    /// A use newer than the copy counts; one from before it — a reinstall keeps the old date — does not.
    package static func hasBeenLaunched(lastUsedDate: Date?, dateAdded: Date?) -> Bool {
        guard let lastUsedDate else { return false }
        guard let dateAdded else { return true }
        return lastUsedDate > dateAdded
    }
}
