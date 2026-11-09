import Foundation

/// How the layout must change to match the applications installed; the bookkeeping half of macOS 15's
/// `LPAppManager`.
///
/// An entry in the layout stands for one bundle: the one its bookmark leads to, as long as that bundle
/// still has the entry's identifier. When the bookmark leads nowhere, or to a bundle replaced in place by
/// one with another identifier (a Setapp build, a fork), the entry leaves; a second entry for a bundle
/// another entry already stands for leaves too. So a bundle outside the search directories keeps its place,
/// and a deleted copy of an application installed several times over (Xcode) does not linger by taking
/// over another copy under its old name. Only an entry without a bookmark falls back to its identifier: any
/// copy, found by discovery or elsewhere, that no other entry stands for.
///
/// Additions follow what discovery found: every bundle no entry stands for, so each installed copy of an
/// application has its own icon, as in macOS 15.
///
/// The one exception is a launcher of Launchpad or Apps
/// (``ApplicationExclusionList/isLaunchpadLauncher(bundleIdentifier:)``), which leaves whether installed
/// or not.
package struct LayoutReconciliation: Sendable, Equatable {
    /// Applications to put at the end of the layout, in this order.
    package var applicationsToAdd: [DiscoveredApplication] = []
    /// Applications to drop, together with the folders and pages that dropping them leaves empty.
    package var itemsToRemove: [LaunchpadItemIdentifier] = []
    /// The bundle each application that stays stands for.
    package var bundleURLs: [LaunchpadItemIdentifier: URL] = [:]

    package var isEmpty: Bool {
        applicationsToAdd.isEmpty && itemsToRemove.isEmpty
    }

    package init(
        applicationsToAdd: [DiscoveredApplication] = [],
        itemsToRemove: [LaunchpadItemIdentifier] = [],
        bundleURLs: [LaunchpadItemIdentifier: URL] = [:]
    ) {
        self.applicationsToAdd = applicationsToAdd
        self.itemsToRemove = itemsToRemove
        self.bundleURLs = bundleURLs
    }

    /// - Parameters:
    ///   - bookmarkedBundle: Where an application's bookmark leads now.
    ///   - installedBundleURLs: Copies of the application with an identifier installed outside the search
    ///     directories too.
    package static func plan(
        layout: LaunchpadLayout,
        discoveredApplications: [DiscoveredApplication],
        bookmarkedBundle: (LaunchpadApplication) -> BookmarkedBundle,
        installedBundleURLs: (String) -> [URL]
    ) -> LayoutReconciliation {
        var reconciliation = LayoutReconciliation()
        let goneApplicationIdentifiers = assignBundles(
            to: layout.applications,
            discoveredApplications: discoveredApplications,
            bookmarkedBundle: bookmarkedBundle,
            installedBundleURLs: installedBundleURLs,
            bundleURLs: &reconciliation.bundleURLs
        )

        let standingPaths = Set(reconciliation.bundleURLs.values.map(comparablePath(of:)))
        reconciliation.applicationsToAdd = discoveredApplications
            .filter { !standingPaths.contains(comparablePath(of: $0.url)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        func isGone(_ application: LaunchpadApplication) -> Bool {
            goneApplicationIdentifiers.contains(application.identifier)
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

    /// Gives each application the bundle it stands for, in layout order, and returns those left without one.
    private static func assignBundles(
        to applications: [LaunchpadApplication],
        discoveredApplications: [DiscoveredApplication],
        bookmarkedBundle: (LaunchpadApplication) -> BookmarkedBundle,
        installedBundleURLs: (String) -> [URL],
        bundleURLs: inout [LaunchpadItemIdentifier: URL]
    ) -> Set<LaunchpadItemIdentifier> {
        let bookmarkedBundles = applications.map(bookmarkedBundle)
        // A bundle belongs to the first entry whose bookmark leads to it; any later one is a duplicate.
        var ownersByPath: [String: LaunchpadItemIdentifier] = [:]
        for (application, bookmarkedBundle) in zip(applications, bookmarkedBundles) {
            if case .found(let bundleURL) = bookmarkedBundle, ownersByPath[comparablePath(of: bundleURL)] == nil {
                ownersByPath[comparablePath(of: bundleURL)] = application.identifier
            }
        }
        let discoveredURLsByBundleIdentifier = Dictionary(grouping: discoveredApplications, by: \.bundleIdentifier).mapValues { $0.map(\.url) }

        var goneApplicationIdentifiers: Set<LaunchpadItemIdentifier> = []
        for (application, bookmarkedBundle) in zip(applications, bookmarkedBundles) {
            if ApplicationExclusionList.isLaunchpadLauncher(bundleIdentifier: application.bundleIdentifier) {
                goneApplicationIdentifiers.insert(application.identifier)
                continue
            }
            switch bookmarkedBundle {
            case .found(let bundleURL):
                if ownersByPath[comparablePath(of: bundleURL)] == application.identifier {
                    bundleURLs[application.identifier] = bundleURL
                } else {
                    goneApplicationIdentifiers.insert(application.identifier)
                }
                continue
            case .replaced:
                goneApplicationIdentifiers.insert(application.identifier)
                continue
            case .missing:
                // The bundle this entry stood for is gone. Another copy with its identifier is another
                // application — `Xcode-16.4.0` must not come back as Xcode 27 — and gets its own entry.
                guard application.bookmarkData == nil else {
                    goneApplicationIdentifiers.insert(application.identifier)
                    continue
                }
            }
            let candidateURLs = (discoveredURLsByBundleIdentifier[application.bundleIdentifier] ?? []) + installedBundleURLs(application.bundleIdentifier)
            if let bundleURL = candidateURLs.first(where: { ownersByPath[comparablePath(of: $0)] == nil }) {
                ownersByPath[comparablePath(of: bundleURL)] = application.identifier
                bundleURLs[application.identifier] = bundleURL
            } else {
                goneApplicationIdentifiers.insert(application.identifier)
            }
        }
        return goneApplicationIdentifiers
    }

    /// The same bundle reached two ways — by a bookmark, by discovery, through `/private` — compares equal.
    private static func comparablePath(of bundleURL: URL) -> String {
        bundleURL.resolvingSymlinksInPath().standardizedFileURL.path
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
                var record = discoveredApplication.record
                // macOS 15 marked an application when its App Store download finished; one carrying a
                // purchase receipt is the closest the directory shows of that.
                if RecentlyAddedApplications.isFromAppStore(applicationAt: discoveredApplication.url) {
                    record.itemFlags = LaunchpadDatabaseSchema.ItemFlags.recentlyAdded
                }
                try appendApplicationToLastPage(record, itemsPerPage: itemsPerPage)
            }
        }
    }
}
