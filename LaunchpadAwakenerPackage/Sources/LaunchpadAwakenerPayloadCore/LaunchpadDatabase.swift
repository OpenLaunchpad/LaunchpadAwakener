import Darwin
import Foundation
import OSLog
import SQLite3

/// Read-only access to the layout macOS 15's Launchpad left behind.
///
/// The Dock kept it in `$(getconf DARWIN_USER_DIR)com.apple.dock.launchpad/db/db` (schema version 13),
/// and upgrading to macOS 26 or 27 does not delete it. The prototype only reads; it never writes, so
/// the original layout stays intact for a later import.
enum LaunchpadDatabase {
    struct PageItem {
        enum Kind {
            case application
            case folder
        }

        let kind: Kind
        let title: String
        /// Present for applications; folders have none.
        let bundleIdentifier: String?
        /// The 256-point PNG the old Launchpad cached for this item, when it had one.
        let iconPNGData: Data?
    }

    private static let logger = Logger(subsystem: "com.MxIris.LaunchpadAwakener", category: "LaunchpadDatabase")

    /// Item types as stored in the `items` table.
    private static let pageItemType: Int32 = 3
    private static let applicationItemType: Int32 = 4
    private static let folderItemType: Int32 = 2

    static var databasePath: String? {
        let bufferLength = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        guard bufferLength > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: bufferLength)
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, bufferLength) > 0 else { return nil }
        let userDirectoryPath = String(cString: buffer)
        return (userDirectoryPath as NSString).appendingPathComponent("com.apple.dock.launchpad/db/db")
    }

    /// The items on the first page of the root, in the order the old Launchpad showed them.
    static func firstPageItems() -> [PageItem] {
        withReadOnlyConnection { databaseConnection in
            guard
                let rootIdentifier = queryIntegers(
                    "SELECT value FROM dbinfo WHERE key = 'launchpad_root'",
                    on: databaseConnection
                ).first,
                // The root's first child by ordering is `HOLDINGPAGE`, an invisible page the old
                // Launchpad parked unplaced items on; the visible pages follow it.
                let firstPageIdentifier = queryIntegers(
                    "SELECT rowid FROM items WHERE parent_id = \(rootIdentifier) AND type = \(pageItemType) AND uuid NOT LIKE 'HOLDINGPAGE%' ORDER BY ordering LIMIT 1",
                    on: databaseConnection
                ).first
            else {
                logger.error("Could not locate the first page")
                return []
            }

            let pageItems = readPageItems(
                """
                SELECT items.type, coalesce(apps.title, groups.title, ''), apps.bundleid, image_cache.image_data
                FROM items
                LEFT JOIN apps ON apps.item_id = items.rowid
                LEFT JOIN groups ON groups.item_id = items.rowid
                LEFT JOIN image_cache ON image_cache.item_id = items.rowid
                WHERE items.parent_id = \(firstPageIdentifier)
                ORDER BY items.ordering
                """,
                on: databaseConnection
            )
            logger.info("Read \(pageItems.count, privacy: .public) item(s) from the first page")
            return pageItems
        } ?? []
    }

    /// Every application the old Launchpad knew, wherever it was placed — what search filters.
    static func allApplications() -> [PageItem] {
        withReadOnlyConnection { databaseConnection in
            readPageItems(
                """
                SELECT items.type, coalesce(apps.title, ''), apps.bundleid, image_cache.image_data
                FROM items
                JOIN apps ON apps.item_id = items.rowid
                LEFT JOIN image_cache ON image_cache.item_id = items.rowid
                WHERE items.type = \(applicationItemType)
                ORDER BY apps.title COLLATE NOCASE
                """,
                on: databaseConnection
            )
        } ?? []
    }

    private static func withReadOnlyConnection<Result>(_ body: (OpaquePointer?) -> Result) -> Result? {
        guard let databasePath, FileManager.default.fileExists(atPath: databasePath) else {
            logger.error("No old Launchpad database found")
            return nil
        }

        var databaseConnection: OpaquePointer?
        guard sqlite3_open_v2(databasePath, &databaseConnection, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            logger.error("Could not open \(databasePath, privacy: .public)")
            sqlite3_close(databaseConnection)
            return nil
        }
        defer { sqlite3_close(databaseConnection) }
        return body(databaseConnection)
    }

    /// Reads rows of (type, title, bundle identifier, icon PNG) into page items.
    private static func readPageItems(_ statementText: String, on databaseConnection: OpaquePointer?) -> [PageItem] {
        var itemsStatement: OpaquePointer?
        guard sqlite3_prepare_v2(databaseConnection, statementText, -1, &itemsStatement, nil) == SQLITE_OK else {
            logger.error("Could not prepare an item query")
            return []
        }
        defer { sqlite3_finalize(itemsStatement) }

        var pageItems: [PageItem] = []
        while sqlite3_step(itemsStatement) == SQLITE_ROW {
            let kind: PageItem.Kind
            switch sqlite3_column_int(itemsStatement, 0) {
            case applicationItemType: kind = .application
            case folderItemType: kind = .folder
            default: continue
            }
            let title = sqlite3_column_text(itemsStatement, 1).map { String(cString: $0) } ?? ""
            let bundleIdentifier = sqlite3_column_text(itemsStatement, 2).map { String(cString: $0) }
            var iconPNGData: Data?
            if let iconBytes = sqlite3_column_blob(itemsStatement, 3) {
                iconPNGData = Data(bytes: iconBytes, count: Int(sqlite3_column_bytes(itemsStatement, 3)))
            }
            pageItems.append(PageItem(kind: kind, title: title, bundleIdentifier: bundleIdentifier, iconPNGData: iconPNGData))
        }
        return pageItems
    }

    private static func queryIntegers(_ statementText: String, on databaseConnection: OpaquePointer?) -> [Int64] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(databaseConnection, statementText, -1, &statement, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(statement) }
        var values: [Int64] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            values.append(sqlite3_column_int64(statement, 0))
        }
        return values
    }
}
