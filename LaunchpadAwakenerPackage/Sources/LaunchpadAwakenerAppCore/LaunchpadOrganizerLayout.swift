import Foundation
import LaunchpadAwakenerPayloadInterface

/// The Launchpad layout as the organizer window shows it.
///
/// Made from the payload's snapshot, so that the app's public interface carries none of the wire types.
/// Item identifiers are good only for the ``Layout/revision`` they came with.
extension LaunchpadOrganizer {
    public struct ItemIdentifier: Hashable, Sendable, CustomStringConvertible {
        public let rawValue: Int64

        public init(rawValue: Int64) {
            self.rawValue = rawValue
        }

        public var description: String {
            String(rawValue)
        }
    }

    public struct Application: Hashable, Sendable, Identifiable {
        public let id: ItemIdentifier
        public let title: String
        public let bundleIdentifier: String
        /// Where the bundle is; nil when the Dock could not find it.
        public let bundleURL: URL?

        public init(id: ItemIdentifier, title: String, bundleIdentifier: String, bundleURL: URL?) {
            self.id = id
            self.title = title
            self.bundleIdentifier = bundleIdentifier
            self.bundleURL = bundleURL
        }
    }

    public struct Folder: Hashable, Sendable, Identifiable {
        public let id: ItemIdentifier
        public let title: String
        /// Across the folder's pages, in order.
        public let applications: [Application]

        public init(id: ItemIdentifier, title: String, applications: [Application]) {
            self.id = id
            self.title = title
            self.applications = applications
        }
    }

    public enum Item: Hashable, Sendable, Identifiable {
        case application(Application)
        case folder(Folder)

        public var id: ItemIdentifier {
            switch self {
            case .application(let application): application.id
            case .folder(let folder): folder.id
            }
        }

        public var title: String {
            switch self {
            case .application(let application): application.title
            case .folder(let folder): folder.title
            }
        }
    }

    public struct Page: Hashable, Sendable, Identifiable {
        public let id: ItemIdentifier
        /// Counted from 1, as the page dots count.
        public let number: Int
        public let items: [Item]

        public init(id: ItemIdentifier, number: Int, items: [Item]) {
            self.id = id
            self.number = number
            self.items = items
        }

        public var folders: [Folder] {
            items.compactMap { item in
                if case .folder(let folder) = item { folder } else { nil }
            }
        }
    }

    /// A page of the springboard or a folder: what the window's sidebar selects and the list shows.
    public enum Container: Hashable, Sendable {
        case page(ItemIdentifier)
        case folder(ItemIdentifier)
    }

    /// Where selected items can be moved.
    public enum MoveDestination: Hashable, Sendable {
        case page(ItemIdentifier)
        case newPage
        case folder(ItemIdentifier)
    }

    public struct Layout: Hashable, Sendable {
        public let revision: Int
        public let pages: [Page]

        public init(revision: Int, pages: [Page]) {
            self.revision = revision
            self.pages = pages
        }

        /// Every application, in layout order, those in folders included.
        public var applications: [Application] {
            pages.flatMap(\.items).flatMap { item -> [Application] in
                switch item {
                case .application(let application): [application]
                case .folder(let folder): folder.applications
                }
            }
        }

        public var folders: [Folder] {
            pages.flatMap(\.folders)
        }

        public func folder(_ folderIdentifier: ItemIdentifier) -> Folder? {
            folders.first { $0.id == folderIdentifier }
        }

        public func page(_ pageIdentifier: ItemIdentifier) -> Page? {
            pages.first { $0.id == pageIdentifier }
        }

        /// The items a container shows: a page's applications and folders, or a folder's applications.
        public func items(in container: Container) -> [Item] {
            switch container {
            case .page(let pageIdentifier): page(pageIdentifier)?.items ?? []
            case .folder(let folderIdentifier): folder(folderIdentifier)?.applications.map(Item.application) ?? []
            }
        }

        /// The folder an application is in; nil for one on a page of its own.
        public func folder(containing applicationIdentifier: ItemIdentifier) -> Folder? {
            folders.first { folder in folder.applications.contains { $0.id == applicationIdentifier } }
        }

        /// The page an item sits on, directly or in a folder.
        public func page(containing itemIdentifier: ItemIdentifier) -> Page? {
            pages.first { page in
                page.items.contains { item in
                    switch item {
                    case .application(let application): application.id == itemIdentifier
                    case .folder(let folder): folder.id == itemIdentifier || folder.applications.contains { $0.id == itemIdentifier }
                    }
                }
            }
        }

        /// `itemIdentifiers` in the order they appear in the layout; any not in it are left out.
        public func inLayoutOrder(_ itemIdentifiers: Set<ItemIdentifier>) -> [ItemIdentifier] {
            var orderedIdentifiers: [ItemIdentifier] = []
            for item in pages.flatMap(\.items) {
                if itemIdentifiers.contains(item.id) {
                    orderedIdentifiers.append(item.id)
                }
                if case .folder(let folder) = item {
                    orderedIdentifiers += folder.applications.map(\.id).filter(itemIdentifiers.contains)
                }
            }
            return orderedIdentifiers
        }

        /// Whether every one of `itemIdentifiers` is an application.
        public func areAllApplications(_ itemIdentifiers: Set<ItemIdentifier>) -> Bool {
            let applicationIdentifiers = Set(applications.map(\.id))
            return !itemIdentifiers.isEmpty && itemIdentifiers.isSubset(of: applicationIdentifiers)
        }
    }
}

extension LaunchpadOrganizer.Layout {
    init(_ snapshot: LayoutSnapshot) {
        func application(_ application: LayoutSnapshot.Application) -> LaunchpadOrganizer.Application {
            LaunchpadOrganizer.Application(
                id: LaunchpadOrganizer.ItemIdentifier(rawValue: application.identifier),
                title: application.title,
                bundleIdentifier: application.bundleIdentifier,
                bundleURL: application.bundlePath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            )
        }
        self.init(revision: snapshot.revision, pages: snapshot.pages.enumerated().map { pageIndex, page in
            LaunchpadOrganizer.Page(
                id: LaunchpadOrganizer.ItemIdentifier(rawValue: page.identifier),
                number: pageIndex + 1,
                items: page.items.map { item in
                    switch item {
                    case .application(let snapshotApplication):
                        .application(application(snapshotApplication))
                    case .folder(let folder):
                        .folder(LaunchpadOrganizer.Folder(
                            id: LaunchpadOrganizer.ItemIdentifier(rawValue: folder.identifier),
                            title: folder.title,
                            applications: folder.pages.flatMap { $0.map(application) }
                        ))
                    }
                }
            )
        })
    }
}
