import Foundation

/// Rearranging the layout, as dragging in macOS 15's Launchpad did.
///
/// Every edit rewrites the orderings of the parents it touches outright, with macOS 15's ordering
/// triggers switched off for the duration, then tidies up the way 15 did: a page over capacity pushes
/// its last items to the start of the next page, and empty folder pages, folders and pages go away.
extension LaunchpadStore {
    // MARK: - Reading the tree

    package func children(of parentIdentifier: LaunchpadItemIdentifier) throws -> [LaunchpadItemIdentifier] {
        try database.rows(
            "SELECT rowid FROM items WHERE parent_id = ? ORDER BY ordering, rowid",
            [.integer(parentIdentifier.rowIdentifier)]
        ).compactMap { $0.first?.integerValue.map(LaunchpadItemIdentifier.init(rowIdentifier:)) }
    }

    package func parent(of itemIdentifier: LaunchpadItemIdentifier) throws -> LaunchpadItemIdentifier {
        guard let parentRowIdentifier = try database.rows(
            "SELECT parent_id FROM items WHERE rowid = ?",
            [.integer(itemIdentifier.rowIdentifier)]
        ).first?.first?.integerValue else {
            throw LaunchpadStoreError.itemNotFound(itemIdentifier)
        }
        return LaunchpadItemIdentifier(rowIdentifier: parentRowIdentifier)
    }

    package func type(of itemIdentifier: LaunchpadItemIdentifier) throws -> LaunchpadDatabaseSchema.ItemType {
        guard let type = try database.rows(
            "SELECT type FROM items WHERE rowid = ?",
            [.integer(itemIdentifier.rowIdentifier)]
        ).first?.first?.integerValue.flatMap(LaunchpadDatabaseSchema.ItemType.init(rawValue:)) else {
            throw LaunchpadStoreError.itemNotFound(itemIdentifier)
        }
        return type
    }

    /// The root's pages in order, holding pages left out.
    private func rootPages() throws -> [LaunchpadItemIdentifier] {
        try database.rows(
            "SELECT rowid FROM items WHERE parent_id = ? AND type = ? AND uuid NOT LIKE ? ORDER BY ordering, rowid",
            [
                .integer(rootIdentifier.rowIdentifier),
                .integer(LaunchpadDatabaseSchema.ItemType.page.rawValue),
                .text(LaunchpadDatabaseSchema.holdingPageIdentifierPrefix + "%"),
            ]
        ).compactMap { $0.first?.integerValue.map(LaunchpadItemIdentifier.init(rowIdentifier:)) }
    }

    // MARK: - Edits

    /// Moves an application or folder to `targetIndex` on `pageIdentifier` — a root page or a folder's page.
    package func moveItem(_ itemIdentifier: LaunchpadItemIdentifier, toIndex targetIndex: Int, onPage pageIdentifier: LaunchpadItemIdentifier, itemsPerPage: Int) throws {
        try performTransaction {
            try detach(itemIdentifier)
            var pageChildren = try children(of: pageIdentifier)
            pageChildren.insert(itemIdentifier, at: min(max(targetIndex, 0), pageChildren.count))
            try setChildren(pageChildren, of: pageIdentifier)
            try tidyUp(itemsPerPage: itemsPerPage)
        }
    }

    /// Makes a folder of `targetItem` and `draggedItem` where `targetItem` was. The dragged item comes
    /// second, as a quick drop puts it; `draggedItemIndex` 0 puts it first, for one placed before the
    /// target inside a folder that opened while it was held over the target.
    @discardableResult
    package func makeFolder(
        merging draggedItem: LaunchpadItemIdentifier,
        with targetItem: LaunchpadItemIdentifier,
        title: String,
        draggedItemIndex: Int = 1,
        itemsPerPage: Int
    ) throws -> LaunchpadItemIdentifier {
        try performTransaction {
            let sourceFolder = try containingFolder(of: draggedItem)
            try detach(draggedItem)
            let targetPage = try parent(of: targetItem)
            let folder = try appendFolder(titled: title, to: targetPage)
            var pageChildren = try children(of: targetPage).filter { $0 != folder.folder }
            guard let targetIndex = pageChildren.firstIndex(of: targetItem) else {
                throw LaunchpadStoreError.itemNotFound(targetItem)
            }
            pageChildren[targetIndex] = folder.folder
            try setChildren(draggedItemIndex <= 0 ? [draggedItem, targetItem] : [targetItem, draggedItem], of: folder.firstPage)
            try setChildren(pageChildren, of: targetPage)
            try tidyUp(itemsPerPage: itemsPerPage)
            if let sourceFolder {
                try dissolveIfAlmostEmpty(sourceFolder, itemsPerPage: itemsPerPage)
            }
            return folder.folder
        }
    }

    /// Puts an application at the end of `folderIdentifier`, on a new folder page if the last one is full.
    package func moveItem(_ itemIdentifier: LaunchpadItemIdentifier, intoFolder folderIdentifier: LaunchpadItemIdentifier, itemsPerPage: Int) throws {
        try performTransaction {
            guard try type(of: folderIdentifier) == .folder else {
                throw LaunchpadStoreError.unexpectedItemType(folderIdentifier, expected: "folder")
            }
            let sourceFolder = try containingFolder(of: itemIdentifier)
            try detach(itemIdentifier)
            let folderPages = try children(of: folderIdentifier)
            let targetPage: LaunchpadItemIdentifier
            if let lastFolderPage = folderPages.last, try children(of: lastFolderPage).count < itemsPerPage {
                targetPage = lastFolderPage
            } else {
                targetPage = try appendPage(to: folderIdentifier)
            }
            try setChildren(try children(of: targetPage) + [itemIdentifier], of: targetPage)
            try tidyUp(itemsPerPage: itemsPerPage)
            if let sourceFolder, sourceFolder != folderIdentifier {
                try dissolveIfAlmostEmpty(sourceFolder, itemsPerPage: itemsPerPage)
            }
        }
    }

    /// Moves an application out of its folder to `targetIndex` on `pageIdentifier`; a folder left with
    /// one application or none is dissolved, its last application taking the folder's place, as 15
    /// dissolved it when the second-to-last one was dragged out.
    package func moveItem(_ itemIdentifier: LaunchpadItemIdentifier, outOfFolderTo targetIndex: Int, onPage pageIdentifier: LaunchpadItemIdentifier, itemsPerPage: Int) throws {
        try performTransaction {
            let sourceFolder = try containingFolder(of: itemIdentifier)
            try moveItem(itemIdentifier, toIndex: targetIndex, onPage: pageIdentifier, itemsPerPage: itemsPerPage)
            if let sourceFolder {
                try dissolveIfAlmostEmpty(sourceFolder, itemsPerPage: itemsPerPage)
            }
        }
    }

    /// Moves an item onto a new page after the last one, as dragging past the last page did; a folder it
    /// leaves with one application or none is dissolved.
    package func moveItemToNewLastPage(_ itemIdentifier: LaunchpadItemIdentifier, itemsPerPage: Int) throws {
        try performTransaction {
            let sourceFolder = try containingFolder(of: itemIdentifier)
            let newPage = try appendPage(to: rootIdentifier)
            try moveItem(itemIdentifier, toIndex: 0, onPage: newPage, itemsPerPage: itemsPerPage)
            if let sourceFolder {
                try dissolveIfAlmostEmpty(sourceFolder, itemsPerPage: itemsPerPage)
            }
        }
    }

    /// Takes out an application that was deleted, as 15 did once its uninstall succeeded
    /// (`-[Springboard _uninstallRunnable:]`): the page closes the gap without pulling items over from
    /// the next one, a folder left with one application dissolves, and an emptied page goes.
    package func removeApplication(_ itemIdentifier: LaunchpadItemIdentifier, itemsPerPage: Int) throws {
        try performTransaction {
            let sourceFolder = try containingFolder(of: itemIdentifier)
            try removeItem(itemIdentifier)
            if let sourceFolder {
                try dissolveIfAlmostEmpty(sourceFolder, itemsPerPage: itemsPerPage)
            }
            try tidyUp(itemsPerPage: itemsPerPage)
        }
    }

    /// The folder `itemIdentifier` sits in, or nil when it sits on a page of the springboard itself.
    private func containingFolder(of itemIdentifier: LaunchpadItemIdentifier) throws -> LaunchpadItemIdentifier? {
        let folderIdentifier = try parent(of: try parent(of: itemIdentifier))
        return (try? type(of: folderIdentifier)) == .folder ? folderIdentifier : nil
    }

    /// 15 dissolved a folder that a drag left with one application or none, wherever the dragged one
    /// went: the last application takes the folder's place, and the folder goes.
    private func dissolveIfAlmostEmpty(_ folderIdentifier: LaunchpadItemIdentifier, itemsPerPage: Int) throws {
        guard (try? type(of: folderIdentifier)) == .folder else { return }
        let remainingApplications = try children(of: folderIdentifier).flatMap { try children(of: $0) }
        guard remainingApplications.count <= 1 else { return }
        let folderPage = try parent(of: folderIdentifier)
        if let lastApplication = remainingApplications.first {
            let folderIndex = try children(of: folderPage).firstIndex(of: folderIdentifier) ?? 0
            try moveItem(lastApplication, toIndex: folderIndex, onPage: folderPage, itemsPerPage: itemsPerPage)
        }
        try removeItem(folderIdentifier)
        try tidyUp(itemsPerPage: itemsPerPage)
    }

    package func renameFolder(_ folderIdentifier: LaunchpadItemIdentifier, to title: String) throws {
        try database.run("UPDATE groups SET title = ? WHERE item_id = ?", [.text(title), .integer(folderIdentifier.rowIdentifier)])
    }

    /// 15's housekeeping after an edit; see the type's description.
    package func tidyUp(itemsPerPage: Int) throws {
        let capacity = max(itemsPerPage, 1)
        let folderIdentifiers = try database.rows(
            "SELECT rowid FROM items WHERE type = ?",
            [.integer(LaunchpadDatabaseSchema.ItemType.folder.rawValue)]
        ).compactMap { $0.first?.integerValue.map(LaunchpadItemIdentifier.init(rowIdentifier:)) }
        for folderIdentifier in folderIdentifiers {
            try spillOver(pages: try children(of: folderIdentifier), container: folderIdentifier, capacity: capacity)
            for folderPage in try children(of: folderIdentifier) where try children(of: folderPage).isEmpty {
                try removeItem(folderPage)
            }
            if try children(of: folderIdentifier).isEmpty {
                try removeItem(folderIdentifier)
            }
        }
        try spillOver(pages: try rootPages(), container: rootIdentifier, capacity: capacity)
        for rootPage in try rootPages() where try children(of: rootPage).isEmpty {
            try removeItem(rootPage)
        }
    }

    // MARK: - Helpers

    /// Where a detached item waits until the same transaction attaches it again. Never a real parent.
    private static let detachedParentIdentifier = LaunchpadItemIdentifier(rowIdentifier: -1)

    /// Takes an item out of its parent, closing the gap; the caller attaches it somewhere else.
    private func detach(_ itemIdentifier: LaunchpadItemIdentifier) throws {
        let parentIdentifier = try parent(of: itemIdentifier)
        let remainingChildren = try children(of: parentIdentifier).filter { $0 != itemIdentifier }
        try setChildren([itemIdentifier], of: Self.detachedParentIdentifier)
        try setChildren(remainingChildren, of: parentIdentifier)
    }

    /// Pages over `capacity` push their last items to the start of the following page, adding a page
    /// at the end of `container` when the last one overflows.
    private func spillOver(pages: [LaunchpadItemIdentifier], container: LaunchpadItemIdentifier, capacity: Int) throws {
        var pages = pages
        var pageIndex = 0
        while pageIndex < pages.count {
            let pageChildren = try children(of: pages[pageIndex])
            if pageChildren.count > capacity {
                if pageIndex == pages.count - 1 {
                    pages.append(try appendPage(to: container))
                }
                let nextPage = pages[pageIndex + 1]
                try setChildren(Array(pageChildren.prefix(capacity)), of: pages[pageIndex])
                try setChildren(Array(pageChildren.dropFirst(capacity)) + (try children(of: nextPage)), of: nextPage)
            }
            pageIndex += 1
        }
    }

    /// Makes `children` exactly the children of `parentIdentifier`, in order, numbered from 1, with the
    /// ordering triggers switched off so they do not renumber behind this.
    private func setChildren(_ orderedChildren: [LaunchpadItemIdentifier], of parentIdentifier: LaunchpadItemIdentifier) throws {
        let triggerKey = LaunchpadDatabaseSchema.InformationKey.ignoreItemUpdateTriggers
        try database.run("UPDATE dbinfo SET value = 1 WHERE key = ?", [.text(triggerKey)])
        do {
            for (childIndex, child) in orderedChildren.enumerated() {
                try database.run(
                    "UPDATE items SET parent_id = ?, ordering = ? WHERE rowid = ?",
                    [.integer(parentIdentifier.rowIdentifier), .integer(Int64(childIndex + 1)), .integer(child.rowIdentifier)]
                )
            }
        } catch {
            try? database.run("UPDATE dbinfo SET value = 0 WHERE key = ?", [.text(triggerKey)])
            throw error
        }
        try database.run("UPDATE dbinfo SET value = 0 WHERE key = ?", [.text(triggerKey)])
    }
}
