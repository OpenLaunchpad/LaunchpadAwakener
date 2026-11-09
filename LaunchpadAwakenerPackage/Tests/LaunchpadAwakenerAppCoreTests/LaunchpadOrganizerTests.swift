import Foundation
import LaunchpadAwakenerPayloadInterface
import SwiftyXPC
import Testing
@testable import LaunchpadAwakenerAppCore

/// A layout of two pages: page 1 holds Alpha, the folder Tools (Hammer, Saw) and Beta; page 2 holds
/// Gamma and the folder Media (Music).
private enum Sample {
    static let pageOne: Int64 = 10
    static let pageTwo: Int64 = 20
    static let alpha: Int64 = 11
    static let tools: Int64 = 12
    static let hammer: Int64 = 13
    static let saw: Int64 = 14
    static let beta: Int64 = 15
    static let gamma: Int64 = 21
    static let media: Int64 = 22
    static let music: Int64 = 23

    static func application(_ identifier: Int64, _ title: String) -> LayoutSnapshot.Application {
        LayoutSnapshot.Application(identifier: identifier, title: title, bundleIdentifier: "com.example.\(title.lowercased())", bundlePath: "/Applications/\(title).app")
    }

    static func snapshot(revision: Int) -> LayoutSnapshot {
        LayoutSnapshot(revision: revision, pages: [
            LayoutSnapshot.Page(identifier: pageOne, items: [
                .application(application(alpha, "Alpha")),
                .folder(LayoutSnapshot.Folder(identifier: tools, title: "Tools", pages: [[application(hammer, "Hammer")], [application(saw, "Saw")]])),
                .application(application(beta, "Beta")),
            ]),
            LayoutSnapshot.Page(identifier: pageTwo, items: [
                .application(application(gamma, "Gamma")),
                .folder(LayoutSnapshot.Folder(identifier: media, title: "Media", pages: [[application(music, "Music")]])),
            ]),
        ])
    }

    static var layout: LaunchpadOrganizer.Layout {
        LaunchpadOrganizer.Layout(snapshot(revision: 1))
    }

    static func identifiers(_ rawValues: Int64...) -> Set<LaunchpadOrganizer.ItemIdentifier> {
        Set(rawValues.map(LaunchpadOrganizer.ItemIdentifier.init(rawValue:)))
    }
}

@Suite("Organizer edits")
struct LaunchpadOrganizerEditsTests {
    @Test("a folder's pages read as one list of applications")
    func folderPagesAreFlattened() {
        #expect(Sample.layout.folder(.init(rawValue: Sample.tools))?.applications.map(\.title) == ["Hammer", "Saw"])
        #expect(Sample.layout.pages.map(\.number) == [1, 2])
    }

    @Test("selected items move in layout order, whatever order they were picked in")
    func moveKeepsLayoutOrder() {
        let edits = LaunchpadOrganizerEdits.move(Sample.identifiers(Sample.gamma, Sample.saw, Sample.alpha), to: .page(.init(rawValue: Sample.pageTwo)), in: Sample.layout)
        #expect(edits == [.moveItemsToEndOfPage(items: [Sample.alpha, Sample.saw, Sample.gamma], page: Sample.pageTwo)])
    }

    @Test("moving into a folder leaves selected folders out")
    func folderDoesNotGoIntoFolder() {
        let edits = LaunchpadOrganizerEdits.move(Sample.identifiers(Sample.media, Sample.beta), to: .folder(.init(rawValue: Sample.tools)), in: Sample.layout)
        #expect(edits == [.moveItemsIntoFolder(items: [Sample.beta], folder: Sample.tools)])
        #expect(LaunchpadOrganizerEdits.move(Sample.identifiers(Sample.media), to: .folder(.init(rawValue: Sample.tools)), in: Sample.layout).isEmpty)
    }

    @Test("a new folder takes two applications or more")
    func newFolderNeedsTwoApplications() {
        #expect(LaunchpadOrganizerEdits.makeFolder(of: Sample.identifiers(Sample.beta, Sample.media), titled: "Pair", in: Sample.layout).isEmpty)
        #expect(
            LaunchpadOrganizerEdits.makeFolder(of: Sample.identifiers(Sample.gamma, Sample.alpha), titled: "Pair", in: Sample.layout)
                == [.makeFolder(items: [Sample.alpha, Sample.gamma], title: "Pair")]
        )
    }

    @Test("applications leave their folders for the page each folder is on")
    func moveOutOfFolders() {
        let edits = LaunchpadOrganizerEdits.moveOutOfFolders(Sample.identifiers(Sample.music, Sample.saw, Sample.alpha), in: Sample.layout)
        #expect(edits == [
            .moveItemsToEndOfPage(items: [Sample.saw], page: Sample.pageOne),
            .moveItemsToEndOfPage(items: [Sample.music], page: Sample.pageTwo),
        ])
    }

    @Test("sorting by name arranges the container, and an order already in place sends nothing")
    func sortByName() {
        let page = LaunchpadOrganizer.Container.page(.init(rawValue: Sample.pageOne))
        #expect(LaunchpadOrganizerEdits.sortByName(page, in: Sample.layout) == [.arrange(container: Sample.pageOne, order: [Sample.alpha, Sample.beta, Sample.tools])])
        #expect(LaunchpadOrganizerEdits.sortByName(.folder(.init(rawValue: Sample.tools)), in: Sample.layout).isEmpty)
    }

    @Test("a blank folder name is not sent")
    func blankRenameIsDropped() {
        #expect(LaunchpadOrganizerEdits.renameFolder(.init(rawValue: Sample.tools), to: "  ").isEmpty)
        #expect(LaunchpadOrganizerEdits.renameFolder(.init(rawValue: Sample.tools), to: " Kit ") == [.renameFolder(folder: Sample.tools, title: "Kit")])
    }

    @Test("grouping by category takes only applications outside folders, joins a folder of the same name, and skips a lone application")
    func categoryGroups() {
        let categories = ["Alpha": "Utilities", "Beta": "media", "Gamma": "Utilities", "Hammer": "Utilities", "Music": "Games"]
        let groups = LaunchpadOrganizerEdits.categoryGroups(in: Sample.layout) { bundleURL in
            categories[bundleURL.deletingPathExtension().lastPathComponent]
        }
        #expect(groups.map(\.title) == ["media", "Utilities"])
        #expect(groups.first?.existingFolder == .init(rawValue: Sample.media))
        #expect(groups.last?.applications.map(\.title) == ["Alpha", "Gamma"])
        #expect(LaunchpadOrganizerEdits.groupByCategory(groups) == [
            .moveItemsIntoFolder(items: [Sample.beta], folder: Sample.media),
            .makeFolder(items: [Sample.alpha, Sample.gamma], title: "Utilities"),
        ])
    }
}

/// Stands in for the payload channel: answers from a script and records what it was sent.
private final actor ScriptedLayoutChannel: LayoutChannel {
    var snapshotReplies: [LayoutSnapshotReply]
    var editReplies: [LayoutEditReply]
    private(set) var knownRevisions: [Int?] = []
    private(set) var sentBatches: [(edits: [LayoutEdit], expectedRevision: Int)] = []

    init(snapshotReplies: [LayoutSnapshotReply] = [], editReplies: [LayoutEditReply] = []) {
        self.snapshotReplies = snapshotReplies
        self.editReplies = editReplies
    }

    func fetchLayout(knownRevision: Int?) async throws -> LayoutSnapshotReply {
        knownRevisions.append(knownRevision)
        return snapshotReplies.removeFirst()
    }

    func applyLayoutEdits(_ edits: [LayoutEdit], expectedRevision: Int) async throws -> LayoutEditReply {
        sentBatches.append((edits, expectedRevision))
        return editReplies.removeFirst()
    }
}

@Suite("Organizer")
@MainActor
struct LaunchpadOrganizerTests {
    private func makeOrganizer(_ channel: ScriptedLayoutChannel) -> LaunchpadOrganizer {
        LaunchpadOrganizer(lookUpChannel: { .available(channel) }, categoryName: { _ in nil })
    }

    @Test("the layout is read once, and afterwards only asked whether it changed")
    func refreshAsksWithTheKnownRevision() async {
        let channel = ScriptedLayoutChannel(snapshotReplies: [.snapshot(Sample.snapshot(revision: 4)), .unchanged(revision: 4)])
        let organizer = makeOrganizer(channel)

        await organizer.refresh()
        await organizer.refresh()

        #expect(organizer.availability == .ready)
        #expect(organizer.layout?.revision == 4)
        #expect(await channel.knownRevisions == [nil, 4])
    }

    @Test("an edit is sent with the revision it was worked out from, and the layout that comes back is shown")
    func editCarriesItsRevision() async throws {
        let channel = ScriptedLayoutChannel(snapshotReplies: [.snapshot(Sample.snapshot(revision: 4))], editReplies: [.applied(Sample.snapshot(revision: 5))])
        let organizer = makeOrganizer(channel)
        await organizer.refresh()

        await organizer.dissolveFolder(.init(rawValue: Sample.tools))

        let sentBatch = try #require(await channel.sentBatches.first)
        #expect(sentBatch.expectedRevision == 4)
        #expect(sentBatch.edits == [.dissolveFolder(folder: Sample.tools)])
        #expect(organizer.layout?.revision == 5)
        #expect(organizer.lastErrorDescription == nil)
    }

    @Test("an edit turned away as stale shows the newer layout and says nothing moved")
    func staleEditShowsNewerLayout() async {
        let channel = ScriptedLayoutChannel(snapshotReplies: [.snapshot(Sample.snapshot(revision: 4))], editReplies: [.staleRevision(Sample.snapshot(revision: 7))])
        let organizer = makeOrganizer(channel)
        await organizer.refresh()

        await organizer.dissolveFolder(.init(rawValue: Sample.tools))

        #expect(organizer.layout?.revision == 7)
        #expect(organizer.lastErrorDescription?.contains("nothing was moved") == true)
    }

    @Test("a refused edit keeps the layout and gives the reason")
    func refusedEditGivesTheReason() async {
        let channel = ScriptedLayoutChannel(snapshotReplies: [.snapshot(Sample.snapshot(revision: 4))], editReplies: [.refused(reason: "Launchpad is open.")])
        let organizer = makeOrganizer(channel)
        await organizer.refresh()

        await organizer.dissolveFolder(.init(rawValue: Sample.tools))

        #expect(organizer.layout?.revision == 4)
        #expect(organizer.lastErrorDescription == "Launchpad is open.")
    }

    @Test("an older layout arriving late does not replace a newer one")
    func olderSnapshotIsIgnored() async {
        let channel = ScriptedLayoutChannel(
            snapshotReplies: [.snapshot(Sample.snapshot(revision: 4)), .snapshot(Sample.snapshot(revision: 3))],
            editReplies: [.applied(Sample.snapshot(revision: 5))]
        )
        let organizer = makeOrganizer(channel)
        await organizer.refresh()
        await organizer.dissolveFolder(.init(rawValue: Sample.tools))

        await organizer.refresh()

        #expect(organizer.layout?.revision == 5)
    }

    @Test("without a usable Dock there is no layout, only the reason")
    func unavailableDockShowsTheReason() async {
        let organizer = LaunchpadOrganizer(lookUpChannel: { .unavailable(.stalePayload) }, categoryName: { _ in nil })

        await organizer.refresh()

        #expect(organizer.layout == nil)
        #expect(organizer.availability == .unavailable(LayoutUnavailability.stalePayload.description))
    }
}

@Suite("Layout requests on the wire")
struct LayoutRequestEncodingTests {
    @Test("a snapshot with folder pages survives the XPC encoding")
    func snapshotRoundTrip() throws {
        let reply = LayoutSnapshotReply.snapshot(Sample.snapshot(revision: 9))
        let decodedReply = try XPCDecoder().decode(type: LayoutSnapshotReply.self, from: try XPCEncoder().encode(reply))
        #expect(decodedReply == reply)
    }

    @Test("a batch of edits survives the XPC encoding")
    func editRequestRoundTrip() throws {
        let request = LayoutEditRequest(expectedRevision: 3, edits: [
            .moveItemsToEndOfPage(items: [1, 2], page: 10),
            .moveItemsToNewLastPage(items: [3]),
            .moveItemsIntoFolder(items: [4], folder: 12),
            .makeFolder(items: [5, 6], title: "工具"),
            .renameFolder(folder: 12, title: "Kit"),
            .dissolveFolder(folder: 12),
            .arrange(container: 10, order: [2, 1]),
        ])
        let decodedRequest = try XPCDecoder().decode(type: LayoutEditRequest.self, from: try XPCEncoder().encode(request))
        #expect(decodedRequest.expectedRevision == 3)
        #expect(decodedRequest.edits == request.edits)
    }
}
