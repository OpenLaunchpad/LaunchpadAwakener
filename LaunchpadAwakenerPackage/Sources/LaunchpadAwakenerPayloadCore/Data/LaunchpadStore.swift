import Foundation

/// What gets written for one application; the row identifier is assigned by the store.
package struct LaunchpadApplicationRecord: Sendable, Equatable {
    package var title: String
    package var bundleIdentifier: String
    package var storeIdentifier: String?
    package var modificationDate: Double?
    package var bookmarkData: Data?
    package var iconPNGData: Data?
    /// Kept from the legacy database when importing; a fresh UUID otherwise.
    package var itemUUID: String?
    package var itemFlags: Int64?

    package init(
        title: String,
        bundleIdentifier: String,
        storeIdentifier: String? = nil,
        modificationDate: Double? = nil,
        bookmarkData: Data? = nil,
        iconPNGData: Data? = nil,
        itemUUID: String? = nil,
        itemFlags: Int64? = nil
    ) {
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.storeIdentifier = storeIdentifier
        self.modificationDate = modificationDate
        self.bookmarkData = bookmarkData
        self.iconPNGData = iconPNGData
        self.itemUUID = itemUUID
        self.itemFlags = itemFlags
    }
}

package enum LaunchpadStoreError: Error, Equatable {
    case itemNotFound(LaunchpadItemIdentifier)
    case unexpectedItemType(LaunchpadItemIdentifier, expected: String)
    case missingRoot
}

/// The layout database this project owns; the counterpart of macOS 15's `LPStorage`.
///
/// Uses macOS 15's schema and triggers (``LaunchpadDatabaseSchema``), so ordering behaves as it did
/// there: an inserted item goes to the end of its parent. Not thread-safe; one owner serialises calls.
package final class LaunchpadStore {
    package let databaseURL: URL
    package let rootIdentifier: LaunchpadItemIdentifier
    /// Shared with the editing extension; nothing outside the store touches it.
    let database: SQLiteDatabase

    /// Opens the database at `databaseURL`, creating it — and its directory — with an empty root when
    /// it does not exist yet.
    package init(databaseURL: URL) throws {
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let database = try SQLiteDatabase(path: databaseURL.path, mode: .readWriteCreate)
        try database.execute("PRAGMA journal_mode = WAL")

        let hasSchema = try !database.rows("SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'dbinfo'").isEmpty
        if !hasSchema {
            try database.transaction {
                try database.execute(LaunchpadDatabaseSchema.creationStatements)
                try database.run(
                    "INSERT INTO dbinfo (key, value) VALUES (?, 0), (?, ?)",
                    [
                        .text(LaunchpadDatabaseSchema.InformationKey.ignoreItemUpdateTriggers),
                        .text(LaunchpadDatabaseSchema.InformationKey.version),
                        .integer(Int64(LaunchpadDatabaseSchema.version)),
                    ]
                )
                try database.run(
                    "INSERT INTO items (uuid, flags, type, parent_id) VALUES (?, 0, ?, 0)",
                    [.text(LaunchpadDatabaseSchema.rootPageIdentifier), .integer(LaunchpadDatabaseSchema.ItemType.root.rawValue)]
                )
                try database.run(
                    "INSERT INTO dbinfo (key, value) VALUES (?, ?)",
                    [.text(LaunchpadDatabaseSchema.InformationKey.launchpadRoot), .integer(database.lastInsertedRowIdentifier)]
                )
            }
        }

        guard
            let rootRowIdentifier = try database.rows(
                "SELECT value FROM dbinfo WHERE key = ?",
                [.text(LaunchpadDatabaseSchema.InformationKey.launchpadRoot)]
            ).first?.first?.integerValue
        else {
            throw LaunchpadStoreError.missingRoot
        }

        self.databaseURL = databaseURL
        self.database = database
        self.rootIdentifier = LaunchpadItemIdentifier(rowIdentifier: rootRowIdentifier)
    }

    // MARK: - Reading

    /// Whether the root has no page yet: a database created a moment ago, or one emptied by hand.
    package var hasNoPages: Bool {
        get throws {
            try database.rows(
                "SELECT 1 FROM items WHERE parent_id = ? AND type = ? LIMIT 1",
                [.integer(rootIdentifier.rowIdentifier), .integer(LaunchpadDatabaseSchema.ItemType.page.rawValue)]
            ).isEmpty
        }
    }

    package func information(forKey key: String) throws -> String? {
        try database.rows("SELECT value FROM dbinfo WHERE key = ?", [.text(key)]).first?.first?.textValue
    }

    package func setInformation(_ value: String, forKey key: String) throws {
        try database.transaction {
            try database.run("DELETE FROM dbinfo WHERE key = ?", [.text(key)])
            try database.run("INSERT INTO dbinfo (key, value) VALUES (?, ?)", [.text(key), .text(value)])
        }
    }

    /// The whole layout as displayed: the root's pages in order, holding pages left out.
    package func layout() throws -> LaunchpadLayout {
        let itemRows = try database.rows(
            """
            SELECT items.rowid, items.uuid, items.type, items.parent_id,
                   apps.title, apps.bundleid, apps.bookmark, groups.title, image_cache.image_data
            FROM items
            LEFT JOIN apps ON apps.item_id = items.rowid
            LEFT JOIN groups ON groups.item_id = items.rowid
            LEFT JOIN image_cache ON image_cache.item_id = items.rowid
            ORDER BY items.parent_id, items.ordering, items.rowid
            """
        )
        let tree = ItemTree(rows: itemRows)
        let pages = tree.children(of: rootIdentifier, ofType: .page).compactMap { pageRow -> LaunchpadPage? in
            guard !pageRow.isHoldingPage else { return nil }
            let items = tree.children(of: pageRow.identifier).compactMap { itemRow -> LaunchpadItem? in
                switch itemRow.type {
                case .application:
                    itemRow.application.map(LaunchpadItem.application)
                case .folder:
                    .folder(
                        LaunchpadFolder(
                            identifier: itemRow.identifier,
                            title: itemRow.folderTitle ?? "",
                            pages: tree.children(of: itemRow.identifier, ofType: .page).map { folderPageRow in
                                LaunchpadFolderPage(
                                    identifier: folderPageRow.identifier,
                                    applications: tree.children(of: folderPageRow.identifier, ofType: .application).compactMap(\.application)
                                )
                            }
                        )
                    )
                case .root, .page, .downloadingApplication, nil:
                    nil
                }
            }
            return LaunchpadPage(identifier: pageRow.identifier, items: items)
        }
        return LaunchpadLayout(pages: pages)
    }

    // MARK: - Writing

    /// Runs `body` as one transaction, so a failure part-way leaves the layout as it was.
    package func performTransaction<Result>(_ body: () throws -> Result) throws -> Result {
        try database.transaction(body)
    }

    /// Adds an empty page at the end of `containerIdentifier`, the root or a folder.
    @discardableResult
    package func appendPage(to containerIdentifier: LaunchpadItemIdentifier, itemUUID: String? = nil, itemFlags: Int64? = nil) throws -> LaunchpadItemIdentifier {
        try insertItem(type: .page, parent: containerIdentifier, itemUUID: itemUUID, itemFlags: itemFlags)
    }

    /// Adds a folder with one empty page at the end of `pageIdentifier`. Returns the folder and its page.
    @discardableResult
    package func appendFolder(
        titled title: String,
        to pageIdentifier: LaunchpadItemIdentifier,
        itemUUID: String? = nil,
        itemFlags: Int64? = nil
    ) throws -> (folder: LaunchpadItemIdentifier, firstPage: LaunchpadItemIdentifier) {
        let folderIdentifier = try insertItem(type: .folder, parent: pageIdentifier, itemUUID: itemUUID, itemFlags: itemFlags)
        try database.run(
            "INSERT INTO groups (item_id, category_id, title) VALUES (?, NULL, ?)",
            [.integer(folderIdentifier.rowIdentifier), .text(title)]
        )
        let firstPageIdentifier = try appendPage(to: folderIdentifier)
        return (folderIdentifier, firstPageIdentifier)
    }

    /// Adds an application at the end of `pageIdentifier`, a page of the root or of a folder.
    @discardableResult
    package func appendApplication(_ record: LaunchpadApplicationRecord, to pageIdentifier: LaunchpadItemIdentifier) throws -> LaunchpadItemIdentifier {
        let applicationIdentifier = try insertItem(
            type: .application,
            parent: pageIdentifier,
            itemUUID: record.itemUUID,
            itemFlags: record.itemFlags
        )
        try database.run(
            "INSERT INTO apps (item_id, title, bundleid, storeid, category_id, moddate, bookmark) VALUES (?, ?, ?, ?, NULL, ?, ?)",
            [
                .integer(applicationIdentifier.rowIdentifier),
                .text(record.title),
                .text(record.bundleIdentifier),
                record.storeIdentifier.map(SQLiteValue.text) ?? .null,
                record.modificationDate.map(SQLiteValue.real) ?? .null,
                record.bookmarkData.map(SQLiteValue.blob) ?? .null,
            ]
        )
        if let iconPNGData = record.iconPNGData {
            // The `app_inserted` trigger has already added an empty `image_cache` row.
            try database.run(
                "UPDATE image_cache SET image_data = ? WHERE item_id = ?",
                [.blob(iconPNGData), .integer(applicationIdentifier.rowIdentifier)]
            )
        }
        return applicationIdentifier
    }

    /// Adds an application where macOS 15 put a newly installed one: at the end of the last page,
    /// or on a new page when the last one holds `itemsPerPage` items already.
    @discardableResult
    package func appendApplicationToLastPage(_ record: LaunchpadApplicationRecord, itemsPerPage: Int) throws -> LaunchpadItemIdentifier {
        let lastPageRow = try database.rows(
            """
            SELECT pages.rowid, (SELECT count(*) FROM items WHERE items.parent_id = pages.rowid)
            FROM items AS pages
            WHERE pages.parent_id = ? AND pages.type = ? AND pages.uuid NOT LIKE ?
            ORDER BY pages.ordering DESC LIMIT 1
            """,
            [
                .integer(rootIdentifier.rowIdentifier),
                .integer(LaunchpadDatabaseSchema.ItemType.page.rawValue),
                .text(LaunchpadDatabaseSchema.holdingPageIdentifierPrefix + "%"),
            ]
        ).first
        let targetPageIdentifier: LaunchpadItemIdentifier
        if let lastPageRow, let lastPageRowIdentifier = lastPageRow[0].integerValue, (lastPageRow[1].integerValue ?? 0) < Int64(itemsPerPage) {
            targetPageIdentifier = LaunchpadItemIdentifier(rowIdentifier: lastPageRowIdentifier)
        } else {
            targetPageIdentifier = try appendPage(to: rootIdentifier)
        }
        return try appendApplication(record, to: targetPageIdentifier)
    }

    /// Deletes an item and everything inside it.
    package func removeItem(_ itemIdentifier: LaunchpadItemIdentifier) throws {
        let childIdentifiers = try database.rows(
            "SELECT rowid FROM items WHERE parent_id = ?",
            [.integer(itemIdentifier.rowIdentifier)]
        ).compactMap { $0.first?.integerValue }
        for childIdentifier in childIdentifiers {
            try removeItem(LaunchpadItemIdentifier(rowIdentifier: childIdentifier))
        }
        try database.run("DELETE FROM items WHERE rowid = ?", [.integer(itemIdentifier.rowIdentifier)])
    }

    func insertItem(
        type: LaunchpadDatabaseSchema.ItemType,
        parent parentIdentifier: LaunchpadItemIdentifier,
        itemUUID: String?,
        itemFlags: Int64?
    ) throws -> LaunchpadItemIdentifier {
        // `ordering` is filled in by the `insert_item` trigger: the end of the parent.
        try database.run(
            "INSERT INTO items (uuid, flags, type, parent_id) VALUES (?, ?, ?, ?)",
            [
                .text(itemUUID ?? UUID().uuidString),
                .integer(itemFlags ?? 0),
                .integer(type.rawValue),
                .integer(parentIdentifier.rowIdentifier),
            ]
        )
        return LaunchpadItemIdentifier(rowIdentifier: database.lastInsertedRowIdentifier)
    }
}

/// The `items` rows grouped by parent, in `ordering` order.
private struct ItemTree {
    struct ItemRow {
        let identifier: LaunchpadItemIdentifier
        let itemUUID: String
        let type: LaunchpadDatabaseSchema.ItemType?
        let application: LaunchpadApplication?
        let folderTitle: String?

        var isHoldingPage: Bool {
            itemUUID.hasPrefix(LaunchpadDatabaseSchema.holdingPageIdentifierPrefix)
        }
    }

    private var rowsByParent: [LaunchpadItemIdentifier: [ItemRow]] = [:]

    /// `rows` columns: rowid, uuid, type, parent_id, apps.title, apps.bundleid, apps.bookmark,
    /// groups.title, image_cache.image_data — already sorted by parent and ordering.
    init(rows: [[SQLiteValue]]) {
        for row in rows {
            guard let rowIdentifier = row[0].integerValue, let parentRowIdentifier = row[3].integerValue else { continue }
            let identifier = LaunchpadItemIdentifier(rowIdentifier: rowIdentifier)
            let type = row[2].integerValue.flatMap(LaunchpadDatabaseSchema.ItemType.init(rawValue:))
            var application: LaunchpadApplication?
            if type == .application, let bundleIdentifier = row[5].textValue {
                application = LaunchpadApplication(
                    identifier: identifier,
                    title: row[4].textValue ?? bundleIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    bookmarkData: row[6].blobValue,
                    legacyIconPNGData: row[8].blobValue.flatMap { $0.isEmpty ? nil : $0 }
                )
            }
            rowsByParent[LaunchpadItemIdentifier(rowIdentifier: parentRowIdentifier), default: []].append(
                ItemRow(
                    identifier: identifier,
                    itemUUID: row[1].textValue ?? "",
                    type: type,
                    application: application,
                    folderTitle: row[7].textValue
                )
            )
        }
    }

    func children(of parentIdentifier: LaunchpadItemIdentifier) -> [ItemRow] {
        rowsByParent[parentIdentifier] ?? []
    }

    func children(of parentIdentifier: LaunchpadItemIdentifier, ofType type: LaunchpadDatabaseSchema.ItemType) -> [ItemRow] {
        children(of: parentIdentifier).filter { $0.type == type }
    }
}
