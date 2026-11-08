import Foundation

/// Identifies one item of the layout: a page, a folder or an application. The `items` row identifier.
package struct LaunchpadItemIdentifier: Hashable, Comparable, Sendable, CustomStringConvertible {
    package let rowIdentifier: Int64

    package init(rowIdentifier: Int64) {
        self.rowIdentifier = rowIdentifier
    }

    package static func < (lhs: LaunchpadItemIdentifier, rhs: LaunchpadItemIdentifier) -> Bool {
        lhs.rowIdentifier < rhs.rowIdentifier
    }

    package var description: String {
        "#\(rowIdentifier)"
    }
}

package struct LaunchpadApplication: Sendable, Equatable {
    package let identifier: LaunchpadItemIdentifier
    package let title: String
    package let bundleIdentifier: String
    /// Bookmark to the application bundle, as macOS 15 kept it; nil when none was recorded.
    package let bookmarkData: Data?
    /// The 256-point PNG macOS 15 cached for this application; nil for applications added since.
    package let legacyIconPNGData: Data?
    /// Where the bundle is now; the store does not keep it, the library fills it in.
    package let bundleURL: URL?
    /// Downloaded from the App Store and not launched since: the name shows a blue dot.
    package let isRecentlyAdded: Bool

    package init(
        identifier: LaunchpadItemIdentifier,
        title: String,
        bundleIdentifier: String,
        bookmarkData: Data?,
        legacyIconPNGData: Data?,
        bundleURL: URL? = nil,
        isRecentlyAdded: Bool = false
    ) {
        self.identifier = identifier
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.bookmarkData = bookmarkData
        self.legacyIconPNGData = legacyIconPNGData
        self.bundleURL = bundleURL
        self.isRecentlyAdded = isRecentlyAdded
    }

    package func withBundleURL(_ newBundleURL: URL?) -> LaunchpadApplication {
        LaunchpadApplication(
            identifier: identifier,
            title: title,
            bundleIdentifier: bundleIdentifier,
            bookmarkData: bookmarkData,
            legacyIconPNGData: legacyIconPNGData,
            bundleURL: newBundleURL,
            isRecentlyAdded: isRecentlyAdded
        )
    }

    package func withRecentlyAdded(_ newIsRecentlyAdded: Bool) -> LaunchpadApplication {
        LaunchpadApplication(
            identifier: identifier,
            title: title,
            bundleIdentifier: bundleIdentifier,
            bookmarkData: bookmarkData,
            legacyIconPNGData: legacyIconPNGData,
            bundleURL: bundleURL,
            isRecentlyAdded: newIsRecentlyAdded
        )
    }

    /// The bundle's name without `.app`, which search falls back to when the title does not match.
    package var fileName: String? {
        bundleURL.map { $0.deletingPathExtension().lastPathComponent }
    }
}

package struct LaunchpadFolderPage: Sendable, Equatable {
    package let identifier: LaunchpadItemIdentifier
    package let applications: [LaunchpadApplication]

    package init(identifier: LaunchpadItemIdentifier, applications: [LaunchpadApplication]) {
        self.identifier = identifier
        self.applications = applications
    }
}

package struct LaunchpadFolder: Sendable, Equatable {
    package let identifier: LaunchpadItemIdentifier
    package let title: String
    package let pages: [LaunchpadFolderPage]

    package init(identifier: LaunchpadItemIdentifier, title: String, pages: [LaunchpadFolderPage]) {
        self.identifier = identifier
        self.title = title
        self.pages = pages
    }

    package var applications: [LaunchpadApplication] {
        pages.flatMap(\.applications)
    }
}

package enum LaunchpadItem: Sendable, Equatable {
    case application(LaunchpadApplication)
    case folder(LaunchpadFolder)

    package var identifier: LaunchpadItemIdentifier {
        switch self {
        case .application(let application): application.identifier
        case .folder(let folder): folder.identifier
        }
    }

    package var title: String {
        switch self {
        case .application(let application): application.title
        case .folder(let folder): folder.title
        }
    }
}

package struct LaunchpadPage: Sendable, Equatable {
    package let identifier: LaunchpadItemIdentifier
    package let items: [LaunchpadItem]

    package init(identifier: LaunchpadItemIdentifier, items: [LaunchpadItem]) {
        self.identifier = identifier
        self.items = items
    }
}

/// A snapshot of the whole layout, in display order.
package struct LaunchpadLayout: Sendable, Equatable {
    package let pages: [LaunchpadPage]

    package init(pages: [LaunchpadPage]) {
        self.pages = pages
    }

    package static let empty = LaunchpadLayout(pages: [])

    /// The same layout with every application's bundle located by `bundleURL(for:)`.
    package func locatingBundles(_ bundleURL: (LaunchpadApplication) -> URL?) -> LaunchpadLayout {
        mappingApplications { application in
            application.withBundleURL(bundleURL(application))
        }
    }

    /// The same layout with the applications of `bundleIdentifiers` no longer recently added, wherever
    /// they are.
    package func clearingRecentlyAdded(forBundleIdentifiers bundleIdentifiers: Set<String>) -> LaunchpadLayout {
        mappingApplications { application in
            bundleIdentifiers.contains(application.bundleIdentifier) ? application.withRecentlyAdded(false) : application
        }
    }

    private func mappingApplications(_ transform: (LaunchpadApplication) -> LaunchpadApplication) -> LaunchpadLayout {
        LaunchpadLayout(pages: pages.map { page in
            LaunchpadPage(identifier: page.identifier, items: page.items.map { item in
                switch item {
                case .application(let application):
                    .application(transform(application))
                case .folder(let folder):
                    .folder(LaunchpadFolder(
                        identifier: folder.identifier,
                        title: folder.title,
                        pages: folder.pages.map { LaunchpadFolderPage(identifier: $0.identifier, applications: $0.applications.map(transform)) }
                    ))
                }
            })
        })
    }

    package var folders: [LaunchpadFolder] {
        pages.flatMap(\.items).compactMap { item in
            if case .folder(let folder) = item { folder } else { nil }
        }
    }

    /// Every application, those inside folders included, in display order.
    package var applications: [LaunchpadApplication] {
        pages.flatMap(\.items).flatMap { item -> [LaunchpadApplication] in
            switch item {
            case .application(let application): [application]
            case .folder(let folder): folder.applications
            }
        }
    }
}
