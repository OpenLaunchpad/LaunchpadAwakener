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
        /// Whether an application discovery did not find is installed elsewhere.
        package var isStillInstalled: @Sendable (LaunchpadApplication) -> Bool
        /// The first page laid out when there is no macOS 15 layout to import.
        package var defaultMainPage: [DefaultLaunchpadLayout.Entry]

        package init(
            databaseURL: URL,
            legacyDatabaseURL: URL?,
            searchDirectories: [URL],
            exclusionList: ApplicationExclusionList,
            itemsPerPage: Int,
            isStillInstalled: @escaping @Sendable (LaunchpadApplication) -> Bool,
            defaultMainPage: [DefaultLaunchpadLayout.Entry] = DefaultLaunchpadLayout.mainPage
        ) {
            self.databaseURL = databaseURL
            self.legacyDatabaseURL = legacyDatabaseURL
            self.searchDirectories = searchDirectories
            self.exclusionList = exclusionList
            self.itemsPerPage = itemsPerPage
            self.isStillInstalled = isStillInstalled
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
                itemsPerPage: itemsPerPage,
                isStillInstalled: ApplicationDiscovery.isStillInstalled
            )
        }
    }

    private let configuration: Configuration
    private let layoutHandler: @Sendable (LaunchpadLayout) async -> Void
    private var store: LaunchpadStore?
    private var directoryMonitor: ApplicationDirectoryMonitor?
    /// Bundle locations from the latest discovery, by bundle identifier.
    private var discoveredBundleURLs: [String: URL] = [:]
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

    /// Where an application's bundle is: where discovery found it, or else where its bookmark points.
    private func bundleURL(for application: LaunchpadApplication) -> URL? {
        if let discoveredBundleURL = discoveredBundleURLs[application.bundleIdentifier] {
            return discoveredBundleURL
        }
        guard let bookmarkData = application.bookmarkData else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: bookmarkData, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &isStale)
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
        let reconciliation = LayoutReconciliation.plan(
            layout: try store.layout(),
            discoveredApplications: discoveredApplications,
            isStillInstalled: configuration.isStillInstalled
        )
        guard !reconciliation.isEmpty else { return }
        try store.apply(reconciliation, itemsPerPage: configuration.itemsPerPage)
        #log(.info, "Reconciled: added \(reconciliation.applicationsToAdd.map(\.bundleIdentifier), privacy: .public), removed \(reconciliation.itemsToRemove.count, privacy: .public) item(s)")
    }

    private func publish(_ store: LaunchpadStore) async throws {
        let newLayout = try store.layout().locatingBundles { bundleURL(for: $0) }
        guard newLayout != layout else { return }
        layout = newLayout
        #log(.info, "Layout: \(newLayout.pages.count, privacy: .public) page(s), \(newLayout.folders.count, privacy: .public) folder(s), \(newLayout.applications.count, privacy: .public) application(s)")
        await layoutHandler(newLayout)
    }
}
