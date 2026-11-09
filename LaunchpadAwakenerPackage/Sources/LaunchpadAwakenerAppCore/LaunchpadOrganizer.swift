import Foundation
import LaunchpadAwakenerPayloadInterface
import OSToolbox

/// What the organizer window edits the Launchpad layout through.
///
/// The Dock's layout library is the only writer of the layout database, so the window never opens the
/// database: it reads the layout and sends edits over the payload channel. Edits carry the revision they
/// were worked out from; the library turns away a batch from an older revision, because item identifiers
/// can change with every edit — in Launchpad itself, or when an application is installed.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "LaunchpadOrganizer")
@Observable
@MainActor
public final class LaunchpadOrganizer {
    public enum Availability: Equatable, Sendable {
        case loading
        case ready
        /// Why there is no layout to organize, for display.
        case unavailable(String)
    }

    /// The layout as last read from the Dock; nil while there is none to show.
    public private(set) var layout: Layout?
    public private(set) var availability: Availability = .loading
    /// Most recent failure, cleared by the next successful change. For display.
    public private(set) var lastErrorDescription: String?
    /// Whether a batch of edits is on its way to the Dock.
    public private(set) var isApplying = false

    @ObservationIgnored
    private let lookUpChannel: @MainActor () -> LayoutChannelLookup
    @ObservationIgnored
    private let categoryName: @Sendable (URL) -> String?
    /// The channel the current layout came through. A new Dock starts counting revisions afresh.
    @ObservationIgnored
    private var layoutChannelIdentifier: ObjectIdentifier?

    public convenience init(injectionCoordinator: PayloadInjectionCoordinator) {
        self.init(
            lookUpChannel: { [weak injectionCoordinator] in
                injectionCoordinator?.layoutChannelLookup() ?? .unavailable(.notInjected)
            },
            categoryName: LaunchpadOrganizerEdits.categoryName(ofApplicationAt:)
        )
    }

    init(lookUpChannel: @escaping @MainActor () -> LayoutChannelLookup, categoryName: @escaping @Sendable (URL) -> String?) {
        self.lookUpChannel = lookUpChannel
        self.categoryName = categoryName
    }

    // MARK: - Reading

    /// Reads the layout again if it changed. The window calls this every few seconds while it is open.
    public func refresh() async {
        guard !isApplying else { return }
        guard case .available(let channel) = lookUpChannel() else {
            if case .unavailable(let reason) = lookUpChannel() {
                showUnavailable(reason.description)
            }
            return
        }
        let channelIdentifier = ObjectIdentifier(channel)
        let knownRevision = layoutChannelIdentifier == channelIdentifier ? layout?.revision : nil
        do {
            let reply = try await channel.fetchLayout(knownRevision: knownRevision)
            // An edit finished while this was on its way, and brought a newer layout already.
            guard !isApplying else { return }
            switch reply {
            case .snapshot(let snapshot):
                if layoutChannelIdentifier == channelIdentifier, let layout, snapshot.revision < layout.revision {
                    return
                }
                layout = Layout(snapshot)
                layoutChannelIdentifier = channelIdentifier
                availability = .ready
            case .unchanged:
                availability = .ready
            case .unavailable(let reason):
                showUnavailable(reason)
            }
        } catch {
            showUnavailable("The Dock did not send the layout: \(error.localizedDescription)")
        }
    }

    private func showUnavailable(_ reason: String) {
        layout = nil
        layoutChannelIdentifier = nil
        availability = .unavailable(reason)
    }

    // MARK: - Editing

    public func move(_ itemIdentifiers: Set<ItemIdentifier>, to destination: MoveDestination) async {
        guard let layout else { return }
        await apply(LaunchpadOrganizerEdits.move(itemIdentifiers, to: destination, in: layout))
    }

    /// Puts the selected applications into a new folder titled `title`, where the first of them was.
    public func makeFolder(of itemIdentifiers: Set<ItemIdentifier>, titled title: String) async {
        guard let layout else { return }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        await apply(LaunchpadOrganizerEdits.makeFolder(of: itemIdentifiers, titled: trimmedTitle.isEmpty ? "Untitled" : trimmedTitle, in: layout))
    }

    public func moveOutOfFolders(_ itemIdentifiers: Set<ItemIdentifier>) async {
        guard let layout else { return }
        await apply(LaunchpadOrganizerEdits.moveOutOfFolders(itemIdentifiers, in: layout))
    }

    public func renameFolder(_ folderIdentifier: ItemIdentifier, to title: String) async {
        await apply(LaunchpadOrganizerEdits.renameFolder(folderIdentifier, to: title))
    }

    public func dissolveFolder(_ folderIdentifier: ItemIdentifier) async {
        await apply(LaunchpadOrganizerEdits.dissolveFolder(folderIdentifier))
    }

    /// Puts a page's items, or a folder's applications, in `order`.
    public func arrange(_ container: Container, inOrder order: [ItemIdentifier]) async {
        guard let layout else { return }
        await apply(LaunchpadOrganizerEdits.arrange(container, inOrder: order, in: layout))
    }

    public func sortByName(_ container: Container) async {
        guard let layout else { return }
        await apply(LaunchpadOrganizerEdits.sortByName(container, in: layout))
    }

    /// A name for a new folder of `itemIdentifiers`: the App Store category of the first of them that
    /// declares one, as 15 named a folder after its applications' category; "Untitled" otherwise.
    public func suggestedFolderName(for itemIdentifiers: Set<ItemIdentifier>) -> String {
        guard let layout else { return "Untitled" }
        let applicationsByIdentifier = Dictionary(uniqueKeysWithValues: layout.applications.map { ($0.id, $0) })
        for itemIdentifier in layout.inLayoutOrder(itemIdentifiers) {
            if let bundleURL = applicationsByIdentifier[itemIdentifier]?.bundleURL, let category = categoryName(bundleURL) {
                return category
            }
        }
        return "Untitled"
    }

    /// What grouping by App Store category would do, for the user to confirm.
    public func categoryGroups() -> [CategoryGroup] {
        guard let layout else { return [] }
        return LaunchpadOrganizerEdits.categoryGroups(in: layout, categoryName: categoryName)
    }

    public func groupByCategory(_ groups: [CategoryGroup]) async {
        await apply(LaunchpadOrganizerEdits.groupByCategory(groups))
    }

    /// Sends `edits` as one batch, worked out from the layout on show.
    private func apply(_ edits: [LayoutEdit]) async {
        guard !edits.isEmpty, !isApplying, let layout else { return }
        guard case .available(let channel) = lookUpChannel() else {
            if case .unavailable(let reason) = lookUpChannel() {
                lastErrorDescription = reason.description
            }
            return
        }
        isApplying = true
        defer { isApplying = false }
        do {
            let reply = try await channel.applyLayoutEdits(edits, expectedRevision: layout.revision)
            switch reply {
            case .applied(let snapshot):
                self.layout = Layout(snapshot)
                layoutChannelIdentifier = ObjectIdentifier(channel)
                lastErrorDescription = nil
            case .staleRevision(let snapshot):
                self.layout = Layout(snapshot)
                layoutChannelIdentifier = ObjectIdentifier(channel)
                lastErrorDescription = "The layout changed in the meantime, so nothing was moved. Try again."
            case .refused(let reason):
                lastErrorDescription = reason
            case .failed(let reason):
                lastErrorDescription = "Could not change the layout: \(reason)"
            }
            #log(.info, "Sent \(edits.count, privacy: .public) edit(s) from revision \(layout.revision, privacy: .public); the layout is now at \(self.layout?.revision ?? 0, privacy: .public)")
        } catch {
            lastErrorDescription = "The Dock did not answer: \(error.localizedDescription)"
            #log(.error, "Could not send \(edits.count, privacy: .public) edit(s): \(error.localizedDescription, privacy: .public)")
        }
    }
}

/// Reads the layout and applies edits; the payload channel, or a stand-in in tests.
protocol LayoutChannel: AnyObject, Sendable {
    func fetchLayout(knownRevision: Int?) async throws -> LayoutSnapshotReply
    func applyLayoutEdits(_ edits: [LayoutEdit], expectedRevision: Int) async throws -> LayoutEditReply
}

extension PayloadChannel: LayoutChannel {}

/// Whether the organizer can reach the Dock's layout now.
enum LayoutChannelLookup {
    case available(any LayoutChannel)
    case unavailable(LayoutUnavailability)
}

enum LayoutUnavailability: Equatable, CustomStringConvertible {
    case notInjected
    case payloadNotAnswering
    case stalePayload
    case hooksNotInstalled

    var description: String {
        switch self {
        case .notInjected:
            "Launchpad is not running in the Dock. Inject the Dock first."
        case .payloadNotAnswering:
            "The Dock's payload is not answering yet."
        case .stalePayload:
            "The Dock still runs an older build. Restart the Dock to organize Launchpad."
        case .hooksNotInstalled:
            "This Dock build is not supported, so there is no Launchpad layout to organize."
        }
    }
}
