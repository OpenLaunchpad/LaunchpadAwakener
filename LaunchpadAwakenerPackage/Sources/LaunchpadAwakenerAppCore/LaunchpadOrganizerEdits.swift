import Foundation
import LaunchpadAwakenerPayloadInterface
import UniformTypeIdentifiers

extension LaunchpadOrganizer {
    /// Applications that share an App Store category, and the folder they go into: an existing folder
    /// with the category's name, or a new one.
    public struct CategoryGroup: Hashable, Sendable, Identifiable {
        /// The category's name, which is also the folder's.
        public let title: String
        /// The folder of that name already in the layout, if there is one.
        public let existingFolder: ItemIdentifier?
        public let applications: [Application]

        public var id: String { title }

        public init(title: String, existingFolder: ItemIdentifier?, applications: [Application]) {
            self.title = title
            self.existingFolder = existingFolder
            self.applications = applications
        }
    }
}

/// Turns what the user picked in the organizer into edits for the Dock's layout library.
///
/// Selected items always go in layout order, whatever order they were picked in, so that a move keeps
/// them in the order the user saw them.
enum LaunchpadOrganizerEdits {
    typealias Layout = LaunchpadOrganizer.Layout
    typealias ItemIdentifier = LaunchpadOrganizer.ItemIdentifier

    static func move(_ itemIdentifiers: Set<ItemIdentifier>, to destination: LaunchpadOrganizer.MoveDestination, in layout: Layout) -> [LayoutEdit] {
        let orderedIdentifiers = layout.inLayoutOrder(itemIdentifiers)
        switch destination {
        case .page(let pageIdentifier):
            guard !orderedIdentifiers.isEmpty else { return [] }
            return [.moveItemsToEndOfPage(items: orderedIdentifiers.map(\.rawValue), page: pageIdentifier.rawValue)]
        case .newPage:
            guard !orderedIdentifiers.isEmpty else { return [] }
            return [.moveItemsToNewLastPage(items: orderedIdentifiers.map(\.rawValue))]
        case .folder(let folderIdentifier):
            // A folder cannot go into a folder.
            let applicationIdentifiers = Set(layout.applications.map(\.id))
            let movedApplications = orderedIdentifiers.filter(applicationIdentifiers.contains)
            guard !movedApplications.isEmpty else { return [] }
            return [.moveItemsIntoFolder(items: movedApplications.map(\.rawValue), folder: folderIdentifier.rawValue)]
        }
    }

    /// A new folder of the selected applications; none with fewer than two, as 15 never had one.
    static func makeFolder(of itemIdentifiers: Set<ItemIdentifier>, titled title: String, in layout: Layout) -> [LayoutEdit] {
        let applicationIdentifiers = Set(layout.applications.map(\.id))
        let applications = layout.inLayoutOrder(itemIdentifiers).filter(applicationIdentifiers.contains)
        guard applications.count >= 2 else { return [] }
        return [.makeFolder(items: applications.map(\.rawValue), title: title)]
    }

    /// Each selected application in a folder to the end of the page its folder is on.
    static func moveOutOfFolders(_ itemIdentifiers: Set<ItemIdentifier>, in layout: Layout) -> [LayoutEdit] {
        var editsByFolder: [(page: ItemIdentifier, applications: [ItemIdentifier])] = []
        for page in layout.pages {
            for folder in page.folders {
                let leaving = folder.applications.map(\.id).filter(itemIdentifiers.contains)
                if !leaving.isEmpty {
                    editsByFolder.append((page.id, leaving))
                }
            }
        }
        return editsByFolder.map { page, applications in
            .moveItemsToEndOfPage(items: applications.map(\.rawValue), page: page.rawValue)
        }
    }

    static func renameFolder(_ folderIdentifier: ItemIdentifier, to title: String) -> [LayoutEdit] {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return [] }
        return [.renameFolder(folder: folderIdentifier.rawValue, title: trimmedTitle)]
    }

    static func dissolveFolder(_ folderIdentifier: ItemIdentifier) -> [LayoutEdit] {
        [.dissolveFolder(folder: folderIdentifier.rawValue)]
    }

    /// The container's items in `order`; nothing when that is the order they are already in.
    static func arrange(_ container: LaunchpadOrganizer.Container, inOrder order: [ItemIdentifier], in layout: Layout) -> [LayoutEdit] {
        guard layout.items(in: container).map(\.id) != order else { return [] }
        let containerIdentifier = switch container {
        case .page(let pageIdentifier): pageIdentifier
        case .folder(let folderIdentifier): folderIdentifier
        }
        return [.arrange(container: containerIdentifier.rawValue, order: order.map(\.rawValue))]
    }

    static func sortByName(_ container: LaunchpadOrganizer.Container, in layout: Layout) -> [LayoutEdit] {
        let sortedItems = layout.items(in: container).sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return arrange(container, inOrder: sortedItems.map(\.id), in: layout)
    }

    /// The applications on the pages themselves, not in folders, grouped by the App Store category their
    /// bundle declares. A category goes into the folder of its name if there is one; otherwise it gets a
    /// new folder, but only with two applications or more. Applications that declare none stay put.
    static func categoryGroups(in layout: Layout, categoryName: (URL) -> String?) -> [LaunchpadOrganizer.CategoryGroup] {
        var applicationsByCategory: [String: [LaunchpadOrganizer.Application]] = [:]
        for page in layout.pages {
            for item in page.items {
                guard
                    case .application(let application) = item,
                    let bundleURL = application.bundleURL,
                    let category = categoryName(bundleURL)
                else { continue }
                applicationsByCategory[category, default: []].append(application)
            }
        }
        return applicationsByCategory.compactMap { category, applications in
            let existingFolder = layout.folders.first { $0.title.localizedCaseInsensitiveCompare(category) == .orderedSame }
            guard existingFolder != nil || applications.count >= 2 else { return nil }
            return LaunchpadOrganizer.CategoryGroup(title: category, existingFolder: existingFolder?.id, applications: applications)
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    static func groupByCategory(_ groups: [LaunchpadOrganizer.CategoryGroup]) -> [LayoutEdit] {
        groups.map { group in
            let applications = group.applications.map(\.id.rawValue)
            if let existingFolder = group.existingFolder {
                return .moveItemsIntoFolder(items: applications, folder: existingFolder.rawValue)
            }
            return .makeFolder(items: applications, title: group.title)
        }
    }

    /// The localized name of the App Store category the bundle at `bundleURL` declares, such as
    /// "Developer Tools"; nil for one that declares none. Read afresh from the bundle each time.
    static func categoryName(ofApplicationAt bundleURL: URL) -> String? {
        guard
            let informationDictionary = CFBundleCopyInfoDictionaryForURL(bundleURL as CFURL) as? [String: Any],
            let categoryIdentifier = informationDictionary["LSApplicationCategoryType"] as? String,
            let categoryType = UTType(categoryIdentifier)
        else { return nil }
        return categoryType.localizedDescription
    }
}
