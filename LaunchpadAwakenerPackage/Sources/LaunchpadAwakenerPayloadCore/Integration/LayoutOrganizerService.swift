import Foundation
import LaunchpadAwakenerPayloadInterface
import LaunchpadAwakenerSpringboardCore

/// Answers the app's organizer: the layout as a snapshot, and batches of edits applied by the Dock's
/// layout library, the only writer of the layout database.
enum LayoutOrganizerService {
    static func reply(to request: LayoutSnapshotRequest) async -> LayoutSnapshotReply {
        let published = await LaunchpadServices.library.publishedLayout
        guard published.revision > 0 else {
            return .unavailable(reason: "The Dock has not loaded the Launchpad layout yet.")
        }
        if request.knownRevision == published.revision {
            return .unchanged(revision: published.revision)
        }
        return .snapshot(LayoutSnapshot(published.layout, revision: published.revision))
    }

    static func reply(to request: LayoutEditRequest) async -> LayoutEditReply {
        // An edit while the springboard shows would rearrange it under the pointer, in the middle of a
        // drag perhaps; the window covers the screen anyway, so the organizer cannot be in use then.
        if await MainActor.run(body: { SpringboardController.shared.isVisible }) {
            return .refused(reason: "Launchpad is open. Close it, then try again.")
        }
        let library = LaunchpadServices.library
        let result = await library.apply(request.edits.map(LaunchpadEdit.init), expectedRevision: request.expectedRevision)
        let published = await library.publishedLayout
        let snapshot = LayoutSnapshot(published.layout, revision: published.revision)
        switch result {
        case .applied:
            return .applied(snapshot)
        case .staleRevision:
            return .staleRevision(snapshot)
        case .failed(let description):
            return .failed(reason: description)
        case .unavailable:
            return .refused(reason: "The Dock has not loaded the Launchpad layout yet.")
        }
    }
}

extension LayoutSnapshot {
    /// The organizer's view of `layout`: titles, identifiers and bundle paths only.
    init(_ layout: LaunchpadLayout, revision: Int) {
        func application(_ application: LaunchpadApplication) -> Application {
            Application(
                identifier: application.identifier.rowIdentifier,
                title: application.title,
                bundleIdentifier: application.bundleIdentifier,
                bundlePath: application.bundleURL?.path
            )
        }
        self.init(revision: revision, pages: layout.pages.map { page in
            Page(identifier: page.identifier.rowIdentifier, items: page.items.map { item in
                switch item {
                case .application(let launchpadApplication):
                    .application(application(launchpadApplication))
                case .folder(let folder):
                    .folder(Folder(
                        identifier: folder.identifier.rowIdentifier,
                        title: folder.title,
                        pages: folder.pages.map { folderPage in folderPage.applications.map(application) }
                    ))
                }
            })
        })
    }
}

extension LaunchpadEdit {
    init(_ edit: LayoutEdit) {
        func identifier(_ rowIdentifier: Int64) -> LaunchpadItemIdentifier {
            LaunchpadItemIdentifier(rowIdentifier: rowIdentifier)
        }
        switch edit {
        case let .moveItemsToEndOfPage(items, page):
            self = .moveItemsToEndOfPage(items.map(identifier), page: identifier(page))
        case let .moveItemsToNewLastPage(items):
            self = .moveItemsToNewLastPage(items.map(identifier))
        case let .moveItemsIntoFolder(items, folder):
            self = .moveItemsIntoFolder(items.map(identifier), folder: identifier(folder))
        case let .makeFolder(items, title):
            self = .makeFolderContaining(items.map(identifier), title: title)
        case let .renameFolder(folder, title):
            self = .renameFolder(identifier(folder), title: title)
        case let .dissolveFolder(folder):
            self = .dissolveFolder(identifier(folder))
        case let .arrange(container, order):
            self = .arrange(identifier(container), order: order.map(identifier))
        }
    }
}
