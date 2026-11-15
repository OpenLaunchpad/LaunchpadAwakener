import AppKit
import LaunchpadAwakenerPayloadInterface
import Testing
@testable import LaunchpadAwakenerAppCore
@testable import LaunchpadAwakenerAppUI

/// Drops on the organizer's sidebar, driven through the outline view's own dragging-destination methods
/// with a pointer location, the way AppKit drives them — not by calling `validateDrop` with a row the
/// test picked, which would skip the step where AppKit turns the pointer into a proposal.
///
/// The sidebar shows page 1 with the folder Tools under it, then page 2 with the folder Media. Gamma,
/// on page 2, is dragged onto Tools; what the drop does is read from the edits sent to the Dock.
@Suite("Organizer sidebar drops")
@MainActor
struct OrganizerSidebarDropTests {
    private static let pageOne: Int64 = 10
    private static let tools: Int64 = 12
    private static let pageTwo: Int64 = 20
    private static let gamma: Int64 = 21
    private static let media: Int64 = 22

    /// Where in the folder's row the pointer is, from its top edge.
    enum PointerPosition: String, CaseIterable, CustomTestStringConvertible {
        case topEdge
        case middle
        case bottomEdge

        var testDescription: String { rawValue }

        func point(in rowRect: NSRect) -> NSPoint {
            // The outline view is flipped: its y grows downwards.
            switch self {
            case .topEdge: NSPoint(x: rowRect.midX, y: rowRect.minY + 1)
            case .middle: NSPoint(x: rowRect.midX, y: rowRect.midY)
            case .bottomEdge: NSPoint(x: rowRect.midX, y: rowRect.maxY - 1)
            }
        }
    }

    @Test("a drop anywhere on a folder's row puts the items into that folder", arguments: PointerPosition.allCases)
    func dropOnFolderRowGoesIntoFolder(_ pointerPosition: PointerPosition) async throws {
        let fixture = try await SidebarFixture()
        defer { fixture.close() }

        fixture.drop(Self.gamma, at: pointerPosition.point(in: fixture.outlineView.rect(ofRow: SidebarFixture.toolsRow)))

        let sentEdits = try await fixture.channel.firstSentEdits()
        #expect(sentEdits == [.moveItemsIntoFolder(items: [Self.gamma], folder: Self.tools)])
    }

    // MARK: - Fixture

    private static func snapshot(revision: Int) -> LayoutSnapshot {
        func application(_ identifier: Int64, _ title: String) -> LayoutSnapshot.Application {
            LayoutSnapshot.Application(identifier: identifier, title: title, bundleIdentifier: "com.example.\(title.lowercased())", bundlePath: "/Applications/\(title).app")
        }
        return LayoutSnapshot(revision: revision, pages: [
            LayoutSnapshot.Page(identifier: pageOne, items: [
                .application(application(11, "Alpha")),
                .folder(LayoutSnapshot.Folder(identifier: tools, title: "Tools", pages: [[application(13, "Hammer")]])),
            ]),
            LayoutSnapshot.Page(identifier: pageTwo, items: [
                .application(application(gamma, "Gamma")),
                .folder(LayoutSnapshot.Folder(identifier: media, title: "Media", pages: [[application(23, "Music")]])),
            ]),
        ])
    }

    /// The sidebar in a window that is never ordered front, showing the sample layout.
    @MainActor
    private final class SidebarFixture {
        /// The rows are page 1, Tools, page 2 and Media.
        static let toolsRow = 1

        let channel = RecordingLayoutChannel(snapshot: OrganizerSidebarDropTests.snapshot(revision: 1))
        let viewModel: LaunchpadOrganizerViewModel
        let sidebar: OrganizerSidebarViewController
        let window: NSWindow
        let outlineView: NSOutlineView

        init() async throws {
            let channel = channel
            viewModel = LaunchpadOrganizerViewModel(organizer: LaunchpadOrganizer(lookUpChannel: { .available(channel) }, categoryName: { _ in nil }))
            await viewModel.refresh()
            sidebar = OrganizerSidebarViewController(viewModel: viewModel)
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.animationBehavior = .none
            window.contentView = sidebar.view
            window.layoutIfNeeded()
            outlineView = try #require(Self.descendant(ofType: NSOutlineView.self, in: sidebar.view))
            try #require(outlineView.numberOfRows == 4, "the sidebar shows both pages and both folders")
        }

        func close() {
            window.close()
        }

        /// Drags `itemIdentifier` in from outside the sidebar and drops it at `pointInOutlineView`.
        func drop(_ itemIdentifier: Int64, at pointInOutlineView: NSPoint) {
            let pasteboard = NSPasteboard(name: NSPasteboard.Name("OrganizerSidebarDropTests-\(UUID().uuidString)"))
            pasteboard.clearContents()
            pasteboard.writeObjects([OrganizerPasteboard.pasteboardItem(for: .init(rawValue: itemIdentifier))])
            let draggingInfo = PointerDraggingInfo(
                draggingLocation: outlineView.convert(pointInOutlineView, to: nil),
                draggingPasteboard: pasteboard,
                draggingDestinationWindow: window
            )
            // NSTableView answers NSDraggingDestination's messages without declaring the protocol.
            let destination = unsafeBitCast(outlineView, to: (any NSDraggingDestination).self)
            _ = destination.draggingEntered?(draggingInfo)
            _ = destination.draggingUpdated?(draggingInfo)
            if destination.prepareForDragOperation?(draggingInfo) == true {
                _ = destination.performDragOperation?(draggingInfo)
            }
            destination.concludeDragOperation?(draggingInfo)
            pasteboard.releaseGlobally()
        }

        private static func descendant<View: NSView>(ofType viewType: View.Type, in view: NSView) -> View? {
            if let matchingView = view as? View {
                return matchingView
            }
            for subview in view.subviews {
                if let matchingView = descendant(ofType: viewType, in: subview) {
                    return matchingView
                }
            }
            return nil
        }
    }
}

/// Stands in for the payload channel: always gives the same layout and records the edits it is sent.
final actor RecordingLayoutChannel: LayoutChannel {
    private let snapshot: LayoutSnapshot
    private var sentEdits: [[LayoutEdit]] = []

    init(snapshot: LayoutSnapshot) {
        self.snapshot = snapshot
    }

    func fetchLayout(knownRevision: Int?) async throws -> LayoutSnapshotReply {
        knownRevision == snapshot.revision ? .unchanged(revision: snapshot.revision) : .snapshot(snapshot)
    }

    func applyLayoutEdits(_ edits: [LayoutEdit], expectedRevision: Int) async throws -> LayoutEditReply {
        sentEdits.append(edits)
        return .applied(snapshot)
    }

    /// The first batch of edits sent, waiting up to two seconds for one: a drop sends its edits from a
    /// task of its own.
    func firstSentEdits() async throws -> [LayoutEdit] {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while sentEdits.isEmpty, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        return try #require(sentEdits.first, "no edits were sent to the Dock")
    }
}

/// A drag at a fixed pointer location, carrying what the test put on its pasteboard.
@MainActor
private final class PointerDraggingInfo: NSObject, @MainActor NSDraggingInfo {
    let draggingLocation: NSPoint
    let draggingPasteboard: NSPasteboard
    weak var draggingDestinationWindow: NSWindow?
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1

    init(draggingLocation: NSPoint, draggingPasteboard: NSPasteboard, draggingDestinationWindow: NSWindow) {
        self.draggingLocation = draggingLocation
        self.draggingPasteboard = draggingPasteboard
        self.draggingDestinationWindow = draggingDestinationWindow
    }

    var draggingSourceOperationMask: NSDragOperation { .move }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }

    func slideDraggedImage(to screenPoint: NSPoint) {}
    func resetSpringLoading() {}
    func enumerateDraggingItems(
        options enumerationOptions: NSDraggingItemEnumerationOptions = [],
        for view: NSView?,
        classes classArray: [AnyClass],
        searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:],
        using block: (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void
    ) {}
}
