import Foundation

/// How the layout must change to match the applications installed; the bookkeeping half of macOS 15's
/// `LPAppManager`.
///
/// Additions follow what discovery found. Removals are deliberately conservative: an application the
/// layout holds is dropped only when discovery did not find it *and* it is not installed anywhere else
/// either, so a bundle outside the search directories keeps its place.
package struct LayoutReconciliation: Sendable, Equatable {
    /// Applications to put at the end of the layout, in this order.
    package var applicationsToAdd: [DiscoveredApplication] = []
    /// Applications to drop, together with the folders and pages that dropping them leaves empty.
    package var itemsToRemove: [LaunchpadItemIdentifier] = []

    package var isEmpty: Bool {
        applicationsToAdd.isEmpty && itemsToRemove.isEmpty
    }

    package init(applicationsToAdd: [DiscoveredApplication] = [], itemsToRemove: [LaunchpadItemIdentifier] = []) {
        self.applicationsToAdd = applicationsToAdd
        self.itemsToRemove = itemsToRemove
    }

    package static func plan(
        layout: LaunchpadLayout,
        discoveredApplications: [DiscoveredApplication],
        isStillInstalled: (LaunchpadApplication) -> Bool
    ) -> LayoutReconciliation {
        let discoveredBundleIdentifiers = Set(discoveredApplications.map(\.bundleIdentifier))
        let placedBundleIdentifiers = Set(layout.applications.map(\.bundleIdentifier))

        var reconciliation = LayoutReconciliation()
        var addedBundleIdentifiers: Set<String> = []
        for discoveredApplication in discoveredApplications.sorted(by: { $0.title.localizedStandardCompare($1.title) == .orderedAscending })
        where !placedBundleIdentifiers.contains(discoveredApplication.bundleIdentifier)
            && addedBundleIdentifiers.insert(discoveredApplication.bundleIdentifier).inserted
        {
            reconciliation.applicationsToAdd.append(discoveredApplication)
        }

        func isGone(_ application: LaunchpadApplication) -> Bool {
            !discoveredBundleIdentifiers.contains(application.bundleIdentifier) && !isStillInstalled(application)
        }

        for page in layout.pages {
            var remainingItemCount = page.items.count
            var pageRemovals: [LaunchpadItemIdentifier] = []
            for item in page.items {
                switch item {
                case .application(let application):
                    guard isGone(application) else { continue }
                    pageRemovals.append(application.identifier)
                    remainingItemCount -= 1
                case .folder(let folder):
                    var folderRemovals: [LaunchpadItemIdentifier] = []
                    var remainingFolderPageCount = folder.pages.count
                    for folderPage in folder.pages {
                        let goneApplications = folderPage.applications.filter(isGone)
                        guard !goneApplications.isEmpty else { continue }
                        if goneApplications.count == folderPage.applications.count {
                            folderRemovals.append(folderPage.identifier)
                            remainingFolderPageCount -= 1
                        } else {
                            folderRemovals.append(contentsOf: goneApplications.map(\.identifier))
                        }
                    }
                    if remainingFolderPageCount == 0 {
                        pageRemovals.append(folder.identifier)
                        remainingItemCount -= 1
                    } else {
                        pageRemovals.append(contentsOf: folderRemovals)
                    }
                }
            }
            if remainingItemCount == 0, !pageRemovals.isEmpty {
                reconciliation.itemsToRemove.append(page.identifier)
            } else {
                reconciliation.itemsToRemove.append(contentsOf: pageRemovals)
            }
        }
        return reconciliation
    }
}

extension LaunchpadStore {
    /// Applies `reconciliation` in one transaction; new applications go where macOS 15 put a newly
    /// installed one, the end of the last page.
    package func apply(_ reconciliation: LayoutReconciliation, itemsPerPage: Int) throws {
        guard !reconciliation.isEmpty else { return }
        try performTransaction {
            for itemIdentifier in reconciliation.itemsToRemove {
                try removeItem(itemIdentifier)
            }
            for discoveredApplication in reconciliation.applicationsToAdd {
                try appendApplicationToLastPage(discoveredApplication.record, itemsPerPage: itemsPerPage)
            }
        }
    }
}
