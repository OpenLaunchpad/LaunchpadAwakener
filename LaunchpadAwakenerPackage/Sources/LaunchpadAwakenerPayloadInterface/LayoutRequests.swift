import Foundation
import HelperCommunication

/// What the app's organizer asks the payload about the Launchpad layout, and what it gets back.
///
/// The Dock's layout library is the only writer of the layout database, so the organizer never opens
/// the database itself: it reads a snapshot and sends edits, both through here. Item identifiers are the
/// database's row identifiers, good only for the revision they came with.

/// Asks for the layout, unless it is still at `knownRevision`.
public struct LayoutSnapshotRequest: Codable, Sendable, Request {
    public typealias Response = LayoutSnapshotReply

    public static let identifier = "com.MxIris.LaunchpadAwakener.LayoutSnapshot"

    /// The revision the app already has; nil asks for the layout whatever it is.
    public let knownRevision: Int?

    public init(knownRevision: Int?) {
        self.knownRevision = knownRevision
    }
}

public enum LayoutSnapshotReply: Codable, Sendable, Equatable {
    case snapshot(LayoutSnapshot)
    /// Still at the revision the app asked about.
    case unchanged(revision: Int)
    /// There is no layout to give: the library has not loaded it.
    case unavailable(reason: String)
}

/// Applies `edits` in order, all or none, provided the layout is still at `expectedRevision`.
public struct LayoutEditRequest: Codable, Sendable, Request {
    public typealias Response = LayoutEditReply

    public static let identifier = "com.MxIris.LaunchpadAwakener.LayoutEdit"

    public let expectedRevision: Int
    public let edits: [LayoutEdit]

    public init(expectedRevision: Int, edits: [LayoutEdit]) {
        self.expectedRevision = expectedRevision
        self.edits = edits
    }
}

public enum LayoutEditReply: Codable, Sendable, Equatable {
    /// Stored; the layout as it is now.
    case applied(LayoutSnapshot)
    /// Not stored: the layout changed since the revision the edits were worked out from. The layout as
    /// it is now, to work them out again from.
    case staleRevision(LayoutSnapshot)
    /// Not stored, for a reason the user can act on, such as Launchpad being open.
    case refused(reason: String)
    /// Not stored: an edit failed, and the layout is as it was.
    case failed(reason: String)
}

/// One change to the layout. Identifiers are row identifiers of the snapshot's revision.
public enum LayoutEdit: Codable, Sendable, Equatable {
    /// To the end of a page of the springboard, in this order, out of any folder.
    case moveItemsToEndOfPage(items: [Int64], page: Int64)
    /// Onto a new page after the last one, in this order.
    case moveItemsToNewLastPage(items: [Int64])
    /// Applications to the end of a folder, in this order.
    case moveItemsIntoFolder(items: [Int64], folder: Int64)
    /// A new folder of two applications or more, where the first of them was.
    case makeFolder(items: [Int64], title: String)
    case renameFolder(folder: Int64, title: String)
    /// The folder's applications take its place, and the folder goes.
    case dissolveFolder(folder: Int64)
    /// The items of a page of the springboard, or the applications of a folder, in a new order.
    case arrange(container: Int64, order: [Int64])
}

/// The layout as the organizer shows it: no icons and no bookmarks, which stay in the Dock.
public struct LayoutSnapshot: Codable, Sendable, Equatable {
    /// Goes up by one each time the layout changes.
    public let revision: Int
    public let pages: [Page]

    public init(revision: Int, pages: [Page]) {
        self.revision = revision
        self.pages = pages
    }

    public struct Page: Codable, Sendable, Equatable {
        public let identifier: Int64
        public let items: [Item]

        public init(identifier: Int64, items: [Item]) {
            self.identifier = identifier
            self.items = items
        }
    }

    public enum Item: Codable, Sendable, Equatable {
        case application(Application)
        case folder(Folder)
    }

    public struct Application: Codable, Sendable, Equatable {
        public let identifier: Int64
        public let title: String
        public let bundleIdentifier: String
        /// Where the bundle is, for its icon and its category; nil when it could not be found. Copies of
        /// one application share an identifier but not a path.
        public let bundlePath: String?

        public init(identifier: Int64, title: String, bundleIdentifier: String, bundlePath: String?) {
            self.identifier = identifier
            self.title = title
            self.bundleIdentifier = bundleIdentifier
            self.bundlePath = bundlePath
        }
    }

    public struct Folder: Codable, Sendable, Equatable {
        public let identifier: Int64
        public let title: String
        /// The folder's pages, each a list of applications.
        public let pages: [[Application]]

        public init(identifier: Int64, title: String, pages: [[Application]]) {
            self.identifier = identifier
            self.title = title
            self.pages = pages
        }
    }
}
