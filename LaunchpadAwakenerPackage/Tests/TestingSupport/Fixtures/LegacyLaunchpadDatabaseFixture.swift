import Foundation
import LaunchpadAwakenerSpringboardCore

/// Writes a database the way macOS 15's Launchpad left it on disk.
///
/// Besides the visible pages it reproduces what real databases carry and an importer must step over:
/// the `HOLDINGPAGE` sorted first under the root, the version root with its own holding page, and a
/// page whose parent no longer exists.
package struct LegacyLaunchpadDatabaseFixture {
    package indirect enum Item {
        case application(title: String, bundleIdentifier: String, iconPNGData: Data? = nil)
        case folder(title: String, pages: [[Item]])
        case downloadingApplication(title: String, bundleIdentifier: String)
    }

    package var pages: [[Item]]
    /// Items parked on the root's `HOLDINGPAGE`.
    package var holdingPageItems: [Item] = []

    package init(pages: [[Item]], holdingPageItems: [Item] = []) {
        self.pages = pages
        self.holdingPageItems = holdingPageItems
    }

    package func write(to databaseURL: URL) throws {
        let database = try SQLiteDatabase(path: databaseURL.path, mode: .readWriteCreate)
        try database.execute(LaunchpadDatabaseSchema.creationStatements)
        // Orderings below are written explicitly, as macOS 15 had them, so the triggers stay off
        // until the end.
        try database.run("INSERT INTO dbinfo (key, value) VALUES ('ignore_items_update_triggers', 1)")
        try database.run("INSERT INTO dbinfo (key, value) VALUES ('version', 13)")

        let rootRowIdentifier = try insertItem(uuid: "ROOTPAGE", type: .root, parent: 0, ordering: 0, into: database)
        try database.run("INSERT INTO dbinfo (key, value) VALUES ('launchpad_root', ?)", [.integer(rootRowIdentifier)])

        let holdingPageRowIdentifier = try insertPage(uuid: "HOLDINGPAGE", parent: rootRowIdentifier, ordering: 0, into: database)
        try insertItems(holdingPageItems, onPage: holdingPageRowIdentifier, into: database)

        for (pageIndex, pageItems) in pages.enumerated() {
            let pageRowIdentifier = try insertPage(uuid: UUID().uuidString, parent: rootRowIdentifier, ordering: Int64(pageIndex + 1), into: database)
            try insertItems(pageItems, onPage: pageRowIdentifier, into: database)
        }

        let versionRootRowIdentifier = try insertItem(uuid: "ROOTPAGE_VERS", type: .root, parent: 0, ordering: 0, into: database)
        let versionHoldingPageRowIdentifier = try insertPage(uuid: "HOLDINGPAGE_VERS", parent: versionRootRowIdentifier, ordering: 0, into: database)
        try insertItems(
            [.application(title: "Version Holding", bundleIdentifier: "com.example.version-holding")],
            onPage: versionHoldingPageRowIdentifier,
            into: database
        )
        let orphanPageRowIdentifier = try insertPage(uuid: UUID().uuidString, parent: 9_999, ordering: 0, into: database)
        try insertItems(
            [.application(title: "Orphan", bundleIdentifier: "com.example.orphan")],
            onPage: orphanPageRowIdentifier,
            into: database
        )

        try database.run("UPDATE dbinfo SET value = 0 WHERE key = 'ignore_items_update_triggers'")
    }

    private func insertItems(_ items: [Item], onPage pageRowIdentifier: Int64, into database: SQLiteDatabase) throws {
        for (itemIndex, item) in items.enumerated() {
            let ordering = Int64(itemIndex)
            switch item {
            case let .application(title, bundleIdentifier, iconPNGData):
                let applicationRowIdentifier = try insertItem(uuid: UUID().uuidString, type: .application, parent: pageRowIdentifier, ordering: ordering, into: database)
                try database.run(
                    "INSERT INTO apps (item_id, title, bundleid, storeid, category_id, moddate, bookmark) VALUES (?, ?, ?, NULL, NULL, 768029962.0, NULL)",
                    [.integer(applicationRowIdentifier), .text(title), .text(bundleIdentifier)]
                )
                if let iconPNGData {
                    try database.run(
                        "UPDATE image_cache SET image_data = ?, size_big = 256 WHERE item_id = ?",
                        [.blob(iconPNGData), .integer(applicationRowIdentifier)]
                    )
                }
            case let .folder(title, folderPages):
                let folderRowIdentifier = try insertItem(uuid: UUID().uuidString, type: .folder, parent: pageRowIdentifier, ordering: ordering, into: database)
                try database.run("INSERT INTO groups (item_id, category_id, title) VALUES (?, NULL, ?)", [.integer(folderRowIdentifier), .text(title)])
                for (folderPageIndex, folderPageItems) in folderPages.enumerated() {
                    let folderPageRowIdentifier = try insertPage(uuid: UUID().uuidString, parent: folderRowIdentifier, ordering: Int64(folderPageIndex), into: database)
                    try insertItems(folderPageItems, onPage: folderPageRowIdentifier, into: database)
                }
            case let .downloadingApplication(title, bundleIdentifier):
                let downloadingRowIdentifier = try insertItem(uuid: UUID().uuidString, type: .downloadingApplication, parent: pageRowIdentifier, ordering: ordering, into: database)
                try database.run(
                    "INSERT INTO downloading_apps (item_id, title, bundleid, storeid, category_id, install_path) VALUES (?, ?, ?, NULL, NULL, NULL)",
                    [.integer(downloadingRowIdentifier), .text(title), .text(bundleIdentifier)]
                )
            }
        }
    }

    /// macOS 15 also gave every page a `groups` row with an empty title.
    private func insertPage(uuid: String, parent: Int64, ordering: Int64, into database: SQLiteDatabase) throws -> Int64 {
        let pageRowIdentifier = try insertItem(uuid: uuid, type: .page, parent: parent, ordering: ordering, flags: 2, into: database)
        try database.run("INSERT INTO groups (item_id, category_id, title) VALUES (?, NULL, NULL)", [.integer(pageRowIdentifier)])
        return pageRowIdentifier
    }

    private func insertItem(
        uuid: String,
        type: LaunchpadDatabaseSchema.ItemType,
        parent: Int64,
        ordering: Int64,
        flags: Int64 = 0,
        into database: SQLiteDatabase
    ) throws -> Int64 {
        try database.run(
            "INSERT INTO items (uuid, flags, type, parent_id, ordering) VALUES (?, ?, ?, ?, ?)",
            [.text(uuid), .integer(flags), .integer(type.rawValue), .integer(parent), .integer(ordering)]
        )
        return database.lastInsertedRowIdentifier
    }
}
