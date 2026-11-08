import Darwin
import Foundation

/// Copies the layout macOS 15's Launchpad left behind into a ``LaunchpadStore``.
///
/// The legacy database is only ever opened read-only, so it stays intact for a later re-import. Only
/// what macOS 15 showed is copied: the root's pages in order, their applications and folders, and each
/// folder's pages. Holding pages, items cut off from the root, applications still downloading and
/// pages left empty are skipped.
package enum LegacyLaunchpadImporter {
    package struct Summary: Sendable, Equatable {
        package var pageCount = 0
        package var folderCount = 0
        package var applicationCount = 0

        package init(pageCount: Int = 0, folderCount: Int = 0, applicationCount: Int = 0) {
            self.pageCount = pageCount
            self.folderCount = folderCount
            self.applicationCount = applicationCount
        }
    }

    package enum ImportError: Error, Equatable {
        case storeAlreadyHasPages
        case legacyRootMissing
    }

    /// Where macOS 15 kept the layout: `$(getconf DARWIN_USER_DIR)com.apple.dock.launchpad/db/db`.
    package static var defaultLegacyDatabaseURL: URL? {
        let bufferLength = confstr(_CS_DARWIN_USER_DIR, nil, 0)
        guard bufferLength > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: bufferLength)
        guard confstr(_CS_DARWIN_USER_DIR, &buffer, bufferLength) > 0 else { return nil }
        let userDirectoryPath = String(decoding: buffer.prefix { $0 != 0 }.map(UInt8.init(bitPattern:)), as: UTF8.self)
        return URL(fileURLWithPath: userDirectoryPath, isDirectory: true)
            .appendingPathComponent("com.apple.dock.launchpad/db/db", isDirectory: false)
    }

    /// Copies the visible layout into `store`, which must have no pages yet. All or nothing: a failure
    /// part-way leaves `store` as it was.
    @discardableResult
    package static func importLayout(fromLegacyDatabaseAt legacyDatabaseURL: URL, into store: LaunchpadStore) throws -> Summary {
        guard try store.hasNoPages else { throw ImportError.storeAlreadyHasPages }

        let legacyDatabase = try SQLiteDatabase(path: legacyDatabaseURL.path, mode: .readOnly)
        guard
            let legacyRootRowIdentifier = try legacyDatabase.rows(
                "SELECT value FROM dbinfo WHERE key = ?",
                [.text(LaunchpadDatabaseSchema.InformationKey.launchpadRoot)]
            ).first?.first?.integerValue
        else {
            throw ImportError.legacyRootMissing
        }
        let legacyTree = LegacyItemTree(
            rows: try legacyDatabase.rows(
                """
                SELECT items.rowid, items.uuid, items.flags, items.type, items.parent_id,
                       apps.title, apps.bundleid, apps.storeid, apps.moddate, apps.bookmark,
                       groups.title, image_cache.image_data
                FROM items
                LEFT JOIN apps ON apps.item_id = items.rowid
                LEFT JOIN groups ON groups.item_id = items.rowid
                LEFT JOIN image_cache ON image_cache.item_id = items.rowid
                ORDER BY items.parent_id, items.ordering, items.rowid
                """
            )
        )

        return try store.performTransaction {
            var summary = Summary()
            for legacyPage in legacyTree.children(of: legacyRootRowIdentifier, ofType: .page) where !legacyPage.isHoldingPage {
                let legacyPageItems = legacyTree.children(of: legacyPage.rowIdentifier).filter { legacyItem in
                    legacyItem.application != nil || legacyTree.folderHasApplications(legacyItem)
                }
                guard !legacyPageItems.isEmpty else { continue }

                let pageIdentifier = try store.appendPage(to: store.rootIdentifier, itemUUID: legacyPage.itemUUID, itemFlags: legacyPage.flags)
                summary.pageCount += 1
                for legacyItem in legacyPageItems {
                    if let application = legacyItem.application {
                        try store.appendApplication(application, to: pageIdentifier)
                        summary.applicationCount += 1
                        continue
                    }
                    let (folderIdentifier, firstFolderPageIdentifier) = try store.appendFolder(
                        titled: legacyItem.folderTitle ?? "",
                        to: pageIdentifier,
                        itemUUID: legacyItem.itemUUID,
                        itemFlags: legacyItem.flags
                    )
                    summary.folderCount += 1
                    let legacyFolderPages = legacyTree.children(of: legacyItem.rowIdentifier, ofType: .page)
                        .map { legacyFolderPage in legacyTree.children(of: legacyFolderPage.rowIdentifier).compactMap(\.application) }
                        .filter { !$0.isEmpty }
                    for (folderPageIndex, folderPageApplications) in legacyFolderPages.enumerated() {
                        var folderPageIdentifier = firstFolderPageIdentifier
                        if folderPageIndex > 0 {
                            folderPageIdentifier = try store.appendPage(to: folderIdentifier)
                        }
                        for application in folderPageApplications {
                            try store.appendApplication(application, to: folderPageIdentifier)
                            summary.applicationCount += 1
                        }
                    }
                }
            }
            try store.setInformation("legacy", forKey: LaunchpadDatabaseSchema.InformationKey.layoutOrigin)
            return summary
        }
    }
}

/// The legacy `items` rows grouped by parent, in `ordering` order.
private struct LegacyItemTree {
    struct LegacyItem {
        let rowIdentifier: Int64
        let itemUUID: String
        let flags: Int64?
        let type: LaunchpadDatabaseSchema.ItemType?
        /// Present for applications that have a bundle identifier.
        let application: LaunchpadApplicationRecord?
        let folderTitle: String?

        var isHoldingPage: Bool {
            itemUUID.hasPrefix(LaunchpadDatabaseSchema.holdingPageIdentifierPrefix)
        }
    }

    private var itemsByParent: [Int64: [LegacyItem]] = [:]

    /// `rows` columns: rowid, uuid, flags, type, parent_id, apps.title, apps.bundleid, apps.storeid,
    /// apps.moddate, apps.bookmark, groups.title, image_cache.image_data — sorted by parent and ordering.
    init(rows: [[SQLiteValue]]) {
        for row in rows {
            guard let rowIdentifier = row[0].integerValue, let parentRowIdentifier = row[4].integerValue else { continue }
            let type = row[3].integerValue.flatMap(LaunchpadDatabaseSchema.ItemType.init(rawValue:))
            let itemUUID = row[1].textValue ?? UUID().uuidString
            var application: LaunchpadApplicationRecord?
            if type == .application, let bundleIdentifier = row[6].textValue, !bundleIdentifier.isEmpty {
                application = LaunchpadApplicationRecord(
                    title: row[5].textValue ?? bundleIdentifier,
                    bundleIdentifier: bundleIdentifier,
                    storeIdentifier: row[7].textValue,
                    modificationDate: row[8].realValue,
                    bookmarkData: row[9].blobValue,
                    iconPNGData: row[11].blobValue.flatMap { $0.isEmpty ? nil : $0 },
                    itemUUID: itemUUID,
                    itemFlags: row[2].integerValue
                )
            }
            itemsByParent[parentRowIdentifier, default: []].append(
                LegacyItem(
                    rowIdentifier: rowIdentifier,
                    itemUUID: itemUUID,
                    flags: row[2].integerValue,
                    type: type,
                    application: application,
                    folderTitle: type == .folder ? row[10].textValue : nil
                )
            )
        }
    }

    func children(of parentRowIdentifier: Int64) -> [LegacyItem] {
        itemsByParent[parentRowIdentifier] ?? []
    }

    func children(of parentRowIdentifier: Int64, ofType type: LaunchpadDatabaseSchema.ItemType) -> [LegacyItem] {
        children(of: parentRowIdentifier).filter { $0.type == type }
    }

    /// Whether `item` is a folder with at least one application on one of its pages.
    func folderHasApplications(_ item: LegacyItem) -> Bool {
        guard item.type == .folder else { return false }
        return children(of: item.rowIdentifier, ofType: .page).contains { folderPage in
            children(of: folderPage.rowIdentifier).contains { $0.application != nil }
        }
    }
}
