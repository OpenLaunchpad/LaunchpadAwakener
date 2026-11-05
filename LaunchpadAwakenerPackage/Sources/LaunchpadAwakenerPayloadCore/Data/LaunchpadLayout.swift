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

    package init(
        identifier: LaunchpadItemIdentifier,
        title: String,
        bundleIdentifier: String,
        bookmarkData: Data?,
        legacyIconPNGData: Data?
    ) {
        self.identifier = identifier
        self.title = title
        self.bundleIdentifier = bundleIdentifier
        self.bookmarkData = bookmarkData
        self.legacyIconPNGData = legacyIconPNGData
    }
}

package struct LaunchpadFolderPage: Sendable, Equatable {
    package let identifier: LaunchpadItemIdentifier
    package let applications: [LaunchpadApplication]
}

package struct LaunchpadFolder: Sendable, Equatable {
    package let identifier: LaunchpadItemIdentifier
    package let title: String
    package let pages: [LaunchpadFolderPage]

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
}

/// A snapshot of the whole layout, in display order.
package struct LaunchpadLayout: Sendable, Equatable {
    package let pages: [LaunchpadPage]

    package init(pages: [LaunchpadPage]) {
        self.pages = pages
    }

    package static let empty = LaunchpadLayout(pages: [])

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
