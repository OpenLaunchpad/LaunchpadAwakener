import Foundation
import OSToolbox

/// Owns the layout for the life of the payload; the counterpart of macOS 15's `LPAppManager`.
///
/// On first start it fills its own database: from macOS 15's layout when there is one, otherwise the
/// way macOS 15 set up a new user. Every start, and every change in the application directories, then
/// brings the layout in line with what is installed. Each resulting layout goes to `layoutHandler`.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "LaunchpadLibrary")
package actor LaunchpadLibrary {
    package struct Configuration: Sendable {
        package var databaseURL: URL
        /// macOS 15's database; nil or missing means there is nothing to import.
        package var legacyDatabaseURL: URL?
        package var searchDirectories: [URL]
        package var exclusionList: ApplicationExclusionList
        /// Capacity of a page, and where a new application starts a new page.
        package var itemsPerPage: Int
        /// Where an application's bookmark leads now.
        package var bookmarkedBundle: @Sendable (LaunchpadApplication) -> BookmarkedBundle
        /// Every installed copy of the application with an identifier, outside the search directories too.
        package var installedBundleURLs: @Sendable (String) -> [URL]
        /// The first page laid out when there is no macOS 15 layout to import.
        package var defaultMainPage: [DefaultLaunchpadLayout.Entry]

        package init(
            databaseURL: URL,
            legacyDatabaseURL: URL?,
            searchDirectories: [URL],
            exclusionList: ApplicationExclusionList,
            itemsPerPage: Int,
            bookmarkedBundle: @escaping @Sendable (LaunchpadApplication) -> BookmarkedBundle = ApplicationDiscovery.bookmarkedBundle(of:),
            installedBundleURLs: @escaping @Sendable (String) -> [URL] = ApplicationDiscovery.installedBundleURLs(forBundleIdentifier:),
            defaultMainPage: [DefaultLaunchpadLayout.Entry] = DefaultLaunchpadLayout.mainPage
        ) {
            self.databaseURL = databaseURL
            self.legacyDatabaseURL = legacyDatabaseURL
            self.searchDirectories = searchDirectories
            self.exclusionList = exclusionList
            self.itemsPerPage = itemsPerPage
            self.bookmarkedBundle = bookmarkedBundle
            self.installedBundleURLs = installedBundleURLs
            self.defaultMainPage = defaultMainPage
        }

        /// `~/Library/Application Support/LaunchpadAwakener/Launchpad.db`, imported from where macOS 15
        /// kept its layout, with applications from the places macOS 15 looked.
        package static func standard(itemsPerPage: Int) -> Configuration {
            let applicationSupportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support", isDirectory: true)
            return Configuration(
                databaseURL: applicationSupportDirectory.appendingPathComponent("LaunchpadAwakener/Launchpad.db", isDirectory: false),
                legacyDatabaseURL: LegacyLaunchpadImporter.defaultLegacyDatabaseURL,
                searchDirectories: ApplicationDiscovery.standardSearchDirectories,
                exclusionList: .standard,
                itemsPerPage: itemsPerPage
            )
        }
    }

    private let configuration: Configuration
    private let layoutHandler: @Sendable (LaunchpadLayout) async -> Void
    private var store: LaunchpadStore?
    private var directoryMonitor: ApplicationDirectoryMonitor?
    /// Bundle locations from the latest discovery, by bundle identifier.
    private var discoveredBundleURLs: [String: URL] = [:]
    /// The bundle each application stood for at the latest reconciliation: several entries can share an
    /// identifier — copies of Xcode — and each opens its own.
    private var reconciledBundleURLs: [LaunchpadItemIdentifier: URL] = [:]
    private var pendingReconciliation: Task<Void, Never>?

    package private(set) var layout: LaunchpadLayout = .empty

    package init(configuration: Configuration, layoutHandler: @escaping @Sendable (LaunchpadLayout) async -> Void) {
        self.configuration = configuration
        self.layoutHandler = layoutHandler
    }

    /// Opens the database, fills it on first start, reconciles it with what is installed, and — with
    /// `watchesApplicationDirectories` — keeps it reconciled.
    package func start(watchesApplicationDirectories: Bool = true) async {
        do {
            let openedStore = try LaunchpadStore(databaseURL: configuration.databaseURL)
            store = openedStore
            let discoveredApplications = discoverApplications()
            if try openedStore.hasNoPages {
                try populate(openedStore, discoveredApplications: discoveredApplications)
            }
            try reconcile(openedStore, discoveredApplications: discoveredApplications)
            try await publish(openedStore)
        } catch {
            #log(.error, "Could not load the layout: \(String(describing: error), privacy: .public)")
            return
        }

        guard watchesApplicationDirectories else { return }
        let monitor = ApplicationDirectoryMonitor(directories: configuration.searchDirectories) { [weak self] in
            Task { await self?.scheduleReconciliation() }
        }
        monitor.start()
        directoryMonitor = monitor
    }

    /// Brings the layout in line with what is installed now.
    package func reconcileNow() async {
        guard let store else { return }
        do {
            try reconcile(store, discoveredApplications: discoverApplications())
            try await publish(store)
        } catch {
            #log(.error, "Could not reconcile the layout: \(String(describing: error), privacy: .public)")
        }
    }

    private func scheduleReconciliation() {
        // Installers touch the directories in bursts; settle before scanning.
        pendingReconciliation?.cancel()
        pendingReconciliation = Task {
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled else { return }
            await reconcileNow()
        }
    }

    private func discoverApplications() -> [DiscoveredApplication] {
        let discoveredApplications = ApplicationDiscovery.discoverApplications(in: configuration.searchDirectories, exclusionList: configuration.exclusionList)
        discoveredBundleURLs = [:]
        for discoveredApplication in discoveredApplications where discoveredBundleURLs[discoveredApplication.bundleIdentifier] == nil {
            discoveredBundleURLs[discoveredApplication.bundleIdentifier] = discoveredApplication.url
        }
        return discoveredApplications
    }

    /// Where an application's bundle is: the one it stood for at the latest reconciliation, or else where
    /// its bookmark leads, or else the first copy discovery found with its identifier.
    private func bundleURL(for application: LaunchpadApplication) -> URL? {
        if let reconciledBundleURL = reconciledBundleURLs[application.identifier] {
            return reconciledBundleURL
        }
        if case .found(let bookmarkedBundleURL) = configuration.bookmarkedBundle(application) {
            return bookmarkedBundleURL
        }
        return discoveredBundleURLs[application.bundleIdentifier]
    }

    private func populate(_ store: LaunchpadStore, discoveredApplications: [DiscoveredApplication]) throws {
        if let legacyDatabaseURL = configuration.legacyDatabaseURL, FileManager.default.fileExists(atPath: legacyDatabaseURL.path) {
            do {
                let summary = try LegacyLaunchpadImporter.importLayout(fromLegacyDatabaseAt: legacyDatabaseURL, into: store)
                #log(.info, "Imported macOS 15's layout: \(summary.pageCount, privacy: .public) page(s), \(summary.folderCount, privacy: .public) folder(s), \(summary.applicationCount, privacy: .public) application(s)")
                return
            } catch {
                #log(.error, "Could not import macOS 15's layout, building a new one: \(String(describing: error), privacy: .public)")
            }
        } else {
            #log(.info, "No macOS 15 layout to import; building a new one")
        }
        try store.buildDefaultLayout(from: discoveredApplications, mainPage: configuration.defaultMainPage, itemsPerPage: configuration.itemsPerPage)
    }

    private func reconcile(_ store: LaunchpadStore, discoveredApplications: [DiscoveredApplication]) throws {
        let layout = try store.layout()
        let reconciliation = LayoutReconciliation.plan(
            layout: layout,
            discoveredApplications: discoveredApplications,
            bookmarkedBundle: configuration.bookmarkedBundle,
            installedBundleURLs: configuration.installedBundleURLs
        )
        reconciledBundleURLs = reconciliation.bundleURLs
        guard !reconciliation.isEmpty else { return }
        try store.apply(reconciliation, itemsPerPage: configuration.itemsPerPage)
        // An entry just added stands for the copy discovery found, which its bookmark records: another copy
        // with the same identifier — a second Xcode — is another entry.
        for application in try store.layout().applications where reconciledBundleURLs[application.identifier] == nil {
            if case .found(let bundleURL) = configuration.bookmarkedBundle(application) {
                reconciledBundleURLs[application.identifier] = bundleURL
            }
        }
        let removedApplications = layout.applications
            .filter { reconciliation.bundleURLs[$0.identifier] == nil }
            .map { "\($0.title) [\($0.bundleIdentifier)]" }
        #log(.info, "Reconciled: added \(reconciliation.applicationsToAdd.map(\.bundleIdentifier), privacy: .public), removed \(removedApplications, privacy: .public) in \(reconciliation.itemsToRemove.count, privacy: .public) item(s)")
    }

    var currentStore: LaunchpadStore? {
        store
    }

    var itemsPerPage: Int {
        configuration.itemsPerPage
    }

    func publishCurrentLayout() async throws {
        guard let store else { return }
        try await publish(store)
    }

    func logEditFailure(_ edit: LaunchpadEdit, error: any Error) {
        #log(.error, "Could not apply \(String(describing: edit), privacy: .public): \(String(describing: error), privacy: .public)")
    }

    private func publish(_ store: LaunchpadStore) async throws {
        let newLayout = try store.layout().locatingBundles { bundleURL(for: $0) }
        guard newLayout != layout else { return }
        layout = newLayout
        #log(.info, "Layout: \(newLayout.pages.count, privacy: .public) page(s), \(newLayout.folders.count, privacy: .public) folder(s), \(newLayout.applications.count, privacy: .public) application(s)")
        await layoutHandler(newLayout)
    }
}

/// One change made by hand — dragging or renaming — to apply to the stored layout.
package enum LaunchpadEdit: Sendable, Equatable {
    case move(LaunchpadItemIdentifier, toIndex: Int, onPage: LaunchpadItemIdentifier)
    /// `draggedItemIndex` is where the dragged application goes in the new folder: 1 after the target, 0 before.
    case makeFolder(merging: LaunchpadItemIdentifier, with: LaunchpadItemIdentifier, title: String, draggedItemIndex: Int = 1)
    case moveIntoFolder(LaunchpadItemIdentifier, folder: LaunchpadItemIdentifier)
    case moveOutOfFolder(LaunchpadItemIdentifier, toIndex: Int, onPage: LaunchpadItemIdentifier)
    case moveToNewLastPage(LaunchpadItemIdentifier)
    case renameFolder(LaunchpadItemIdentifier, title: String)
    /// The application was deleted from the disk; `folder` is the folder it was in, if any.
    case removeApplication(LaunchpadItemIdentifier, folder: LaunchpadItemIdentifier?)
}

extension LaunchpadLibrary {
    /// Takes the blue dot off these applications for good, and publishes the result if any had one.
    package func clearRecentlyAdded(forBundleIdentifiers bundleIdentifiers: Set<String>) async {
        guard let store = currentStore else { return }
        do {
            guard try store.clearRecentlyAdded(forBundleIdentifiers: bundleIdentifiers) else { return }
            #log(.info, "No longer marked new, having been launched: \(bundleIdentifiers.sorted(), privacy: .public)")
            try await publishCurrentLayout()
        } catch {
            #log(.error, "Could not clear the recently added mark of \(bundleIdentifiers.sorted(), privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// Applies `edit` to the stored layout and publishes the result. Returns whether it was stored;
    /// a failed edit leaves the layout as it was.
    @discardableResult
    package func apply(_ edit: LaunchpadEdit) async -> Bool {
        guard let store = currentStore else { return false }
        let itemsPerPage = itemsPerPage
        do {
            switch edit {
            case let .move(itemIdentifier, targetIndex, pageIdentifier):
                try store.moveItem(itemIdentifier, toIndex: targetIndex, onPage: pageIdentifier, itemsPerPage: itemsPerPage)
            case let .makeFolder(draggedItem, targetItem, title, draggedItemIndex):
                try store.makeFolder(merging: draggedItem, with: targetItem, title: title, draggedItemIndex: draggedItemIndex, itemsPerPage: itemsPerPage)
            case let .moveIntoFolder(itemIdentifier, folderIdentifier):
                try store.moveItem(itemIdentifier, intoFolder: folderIdentifier, itemsPerPage: itemsPerPage)
            case let .moveOutOfFolder(itemIdentifier, targetIndex, pageIdentifier):
                try store.moveItem(itemIdentifier, outOfFolderTo: targetIndex, onPage: pageIdentifier, itemsPerPage: itemsPerPage)
            case let .moveToNewLastPage(itemIdentifier):
                try store.moveItemToNewLastPage(itemIdentifier, itemsPerPage: itemsPerPage)
            case let .renameFolder(folderIdentifier, title):
                try store.renameFolder(folderIdentifier, to: title)
            case let .removeApplication(itemIdentifier, folderIdentifier):
                try store.removeApplication(itemIdentifier, fromFolder: folderIdentifier, itemsPerPage: itemsPerPage)
            }
            try await publishCurrentLayout()
            return true
        } catch {
            logEditFailure(edit, error: error)
            return false
        }
    }
}
