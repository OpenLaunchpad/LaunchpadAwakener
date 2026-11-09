import Foundation
import LaunchpadAwakenerPayloadInterface
import Testing
@testable import LaunchpadAwakenerAppCore

/// The organizer window's rules, without a window: what the list shows, where Back goes, how the
/// selection follows the layout, and what a drop does. The layout is ``Sample``'s.
@Suite("Organizer view model")
@MainActor
struct LaunchpadOrganizerViewModelTests {
    private typealias ItemIdentifier = LaunchpadOrganizer.ItemIdentifier

    private static func item(_ rawValue: Int64) -> ItemIdentifier {
        ItemIdentifier(rawValue: rawValue)
    }

    /// A view model whose organizer has read `Sample`'s layout, then `laterSnapshots` on later refreshes.
    private static func loadedViewModel(laterSnapshots: [LayoutSnapshot] = []) async -> LaunchpadOrganizerViewModel {
        let channel = ScriptedLayoutChannel(snapshotReplies: [.snapshot(Sample.snapshot(revision: 1))] + laterSnapshots.map { .snapshot($0) })
        let organizer = LaunchpadOrganizer(lookUpChannel: { .available(channel) }, categoryName: { _ in nil })
        let viewModel = LaunchpadOrganizerViewModel(organizer: organizer)
        await viewModel.refresh()
        return viewModel
    }

    /// Sample's layout without the folder Tools: page 1 holds Alpha and Beta only.
    private static func snapshotWithoutTools(revision: Int) -> LayoutSnapshot {
        LayoutSnapshot(revision: revision, pages: [
            LayoutSnapshot.Page(identifier: Sample.pageOne, items: [
                .application(Sample.application(Sample.alpha, "Alpha")),
                .application(Sample.application(Sample.beta, "Beta")),
            ]),
            LayoutSnapshot.Page(identifier: Sample.pageTwo, items: [
                .application(Sample.application(Sample.gamma, "Gamma")),
                .folder(LayoutSnapshot.Folder(identifier: Sample.media, title: "Media", pages: [[Sample.application(Sample.music, "Music")]])),
            ]),
        ])
    }

    // MARK: - What is shown

    @Test("the first page is shown once the layout arrives")
    func firstPageIsShown() async {
        let viewModel = await Self.loadedViewModel()
        #expect(viewModel.selectedContainer == .page(Self.item(Sample.pageOne)))
        #expect(viewModel.rows.map(\.item.title) == ["Alpha", "Tools", "Beta"])
        #expect(viewModel.title == "Page 1")
        #expect(viewModel.subtitle == "3 items")
    }

    @Test("a folder lists its applications under its own name")
    func folderIsListed() async {
        let viewModel = await Self.loadedViewModel()
        viewModel.show(.folder(Self.item(Sample.tools)))
        #expect(viewModel.rows.map(\.item.title) == ["Hammer", "Saw"])
        #expect(viewModel.title == "Tools")
        #expect(viewModel.subtitle == "2 items")
    }

    @Test("a search lists matching applications from every page and folder, with where each one is")
    func searchListsMatchesWithLocation() async {
        let viewModel = await Self.loadedViewModel()
        viewModel.searchText = "mm"
        #expect(viewModel.rows.map(\.item.title) == ["Hammer", "Gamma"])
        #expect(viewModel.rows.map(\.location) == ["Page 1 › Tools", "Page 2"])
        #expect(viewModel.subtitle == "Search results")
        #expect(viewModel.title == "Page 1")
    }

    @Test("a search also matches bundle identifiers, and ignores surrounding spaces")
    func searchMatchesBundleIdentifier() async {
        let viewModel = await Self.loadedViewModel()
        viewModel.searchText = "  com.example.music "
        #expect(viewModel.rows.map(\.item.title) == ["Music"])
    }

    // MARK: - Navigating

    @Test("there is nothing to go back to at first")
    func nothingToGoBackTo() async {
        let viewModel = await Self.loadedViewModel()
        #expect(!viewModel.canGoBack)
    }

    @Test("Back returns to the page or folder shown before, and does not record itself")
    func backReturns() async {
        let viewModel = await Self.loadedViewModel()
        viewModel.show(.folder(Self.item(Sample.tools)))
        viewModel.show(.page(Self.item(Sample.pageTwo)))

        viewModel.goBack()
        #expect(viewModel.selectedContainer == .folder(Self.item(Sample.tools)))
        viewModel.goBack()
        #expect(viewModel.selectedContainer == .page(Self.item(Sample.pageOne)))
        #expect(!viewModel.canGoBack)
    }

    @Test("Back skips a folder that is no longer in the layout")
    func backSkipsRemovedFolder() async {
        let viewModel = await Self.loadedViewModel(laterSnapshots: [Self.snapshotWithoutTools(revision: 2)])
        viewModel.show(.folder(Self.item(Sample.tools)))
        viewModel.show(.page(Self.item(Sample.pageTwo)))
        await viewModel.refresh()

        viewModel.goBack()
        #expect(viewModel.selectedContainer == .page(Self.item(Sample.pageOne)))
    }

    @Test("opening a folder shows it and clears the selection")
    func openingAFolderShowsIt() async {
        let viewModel = await Self.loadedViewModel()
        viewModel.selectedItems = [Self.item(Sample.tools)]
        viewModel.open([Self.item(Sample.tools)])
        #expect(viewModel.selectedContainer == .folder(Self.item(Sample.tools)))
        #expect(viewModel.selectedItems.isEmpty)
    }

    @Test("opening a search result shows where it is, selected, and leaves the search")
    func openingASearchResultShowsWhereItIs() async {
        let viewModel = await Self.loadedViewModel()
        viewModel.searchText = "music"
        viewModel.open([Self.item(Sample.music)])
        #expect(viewModel.selectedContainer == .folder(Self.item(Sample.media)))
        #expect(viewModel.selectedItems == [Self.item(Sample.music)])
        #expect(!viewModel.isSearching)
    }

    @Test("opening an application outside a search does nothing")
    func openingAnApplicationDoesNothing() async {
        let viewModel = await Self.loadedViewModel()
        viewModel.open([Self.item(Sample.alpha)])
        #expect(viewModel.selectedContainer == .page(Self.item(Sample.pageOne)))
    }

    // MARK: - Following the layout

    @Test("when the folder shown goes away, the first page is shown and its items leave the selection")
    func removedFolderFallsBackToFirstPage() async {
        let viewModel = await Self.loadedViewModel(laterSnapshots: [Self.snapshotWithoutTools(revision: 2)])
        viewModel.show(.folder(Self.item(Sample.tools)))
        viewModel.selectedItems = [Self.item(Sample.hammer), Self.item(Sample.alpha)]

        await viewModel.refresh()

        #expect(viewModel.selectedContainer == .page(Self.item(Sample.pageOne)))
        #expect(viewModel.selectedItems == [Self.item(Sample.alpha)])
    }

    // MARK: - Acting on items

    @Test("an action on a selected row applies to the whole selection; on any other row, to that row")
    func targetItemsFollowTheSelection() async {
        let viewModel = await Self.loadedViewModel()
        viewModel.selectedItems = [Self.item(Sample.alpha), Self.item(Sample.beta)]
        #expect(viewModel.targetItems(forRow: Self.item(Sample.beta)) == [Self.item(Sample.alpha), Self.item(Sample.beta)])
        #expect(viewModel.targetItems(forRow: Self.item(Sample.tools)) == [Self.item(Sample.tools)])
    }

    @Test("a new folder takes two applications or more, and no folder")
    func makingAFolder() async {
        let viewModel = await Self.loadedViewModel()
        #expect(viewModel.canMakeFolder(from: [Self.item(Sample.alpha), Self.item(Sample.beta)]))
        #expect(!viewModel.canMakeFolder(from: [Self.item(Sample.alpha)]))
        #expect(!viewModel.canMakeFolder(from: [Self.item(Sample.alpha), Self.item(Sample.tools)]))
    }

    @Test("only applications can move into a folder")
    func movingIntoAFolder() async {
        let viewModel = await Self.loadedViewModel()
        #expect(viewModel.canMoveIntoFolder([Self.item(Sample.alpha), Self.item(Sample.music)]))
        #expect(!viewModel.canMoveIntoFolder([Self.item(Sample.alpha), Self.item(Sample.media)]))
    }

    @Test("Move Out of Folder needs something in a folder")
    func anyInFolder() async {
        let viewModel = await Self.loadedViewModel()
        #expect(viewModel.isAnyInFolder([Self.item(Sample.alpha), Self.item(Sample.saw)]))
        #expect(!viewModel.isAnyInFolder([Self.item(Sample.alpha), Self.item(Sample.tools)]))
    }

    @Test("renaming starts from the folder's name, a new folder from the suggested one")
    func folderNaming() async throws {
        let viewModel = await Self.loadedViewModel()
        let tools = try #require(viewModel.layout?.folder(Self.item(Sample.tools)))
        viewModel.beginRenaming(tools)
        #expect(viewModel.folderNaming?.initialName == "Tools")
        #expect(viewModel.folderNaming?.confirmationTitle == "Rename")

        viewModel.beginNewFolder(from: [Self.item(Sample.alpha), Self.item(Sample.beta)])
        #expect(viewModel.folderNaming?.initialName == "Untitled")
        #expect(viewModel.folderNaming?.title == "New Folder")
    }

    // MARK: - Dropping

    @Test("dropped on a page or folder in the sidebar, items move there")
    func dropOnSidebar() async {
        let viewModel = await Self.loadedViewModel()
        let dragged: Set = [Self.item(Sample.alpha)]
        #expect(viewModel.dropOperation(of: dragged, onto: .container(.page(Self.item(Sample.pageTwo)))) == .move(dragged, to: .page(Self.item(Sample.pageTwo))))
        #expect(viewModel.dropOperation(of: dragged, onto: .container(.folder(Self.item(Sample.media)))) == .move(dragged, to: .folder(Self.item(Sample.media))))
    }

    @Test("dropped on a folder's row, items go into the folder")
    func dropOnFolderRow() async {
        let viewModel = await Self.loadedViewModel()
        let dragged: Set = [Self.item(Sample.beta)]
        #expect(viewModel.dropOperation(of: dragged, onto: .row(Self.item(Sample.tools))) == .move(dragged, to: .folder(Self.item(Sample.tools))))
    }

    @Test("dropped on an application's row in the same page, items go before it, in their order")
    func dropOnApplicationRowReorders() async {
        let viewModel = await Self.loadedViewModel()
        let operation = viewModel.dropOperation(of: [Self.item(Sample.beta), Self.item(Sample.tools)], onto: .row(Self.item(Sample.alpha)))
        #expect(operation == .arrange(.page(Self.item(Sample.pageOne)), inOrder: [Self.item(Sample.tools), Self.item(Sample.beta), Self.item(Sample.alpha)]))
    }

    @Test("dropped on a row in another page, items move to the page shown")
    func dropFromElsewhereMoves() async {
        let viewModel = await Self.loadedViewModel()
        let dragged: Set = [Self.item(Sample.gamma)]
        #expect(viewModel.dropOperation(of: dragged, onto: .row(Self.item(Sample.alpha))) == .move(dragged, to: .page(Self.item(Sample.pageOne))))
    }

    @Test("dropped on the list's empty space, items move to the page or folder shown")
    func dropOnListBackground() async {
        let viewModel = await Self.loadedViewModel()
        viewModel.show(.folder(Self.item(Sample.tools)))
        let dragged: Set = [Self.item(Sample.gamma)]
        #expect(viewModel.dropOperation(of: dragged, onto: .listBackground) == .move(dragged, to: .folder(Self.item(Sample.tools))))
    }

    @Test("a drop is refused onto the dragged row itself, with nothing dragged, and onto search results")
    func refusedDrops() async {
        let viewModel = await Self.loadedViewModel()
        #expect(viewModel.dropOperation(of: [Self.item(Sample.alpha)], onto: .row(Self.item(Sample.alpha))) == nil)
        #expect(viewModel.dropOperation(of: [], onto: .listBackground) == nil)

        viewModel.searchText = "a"
        #expect(viewModel.dropOperation(of: [Self.item(Sample.gamma)], onto: .row(Self.item(Sample.alpha))) == nil)
        #expect(viewModel.dropOperation(of: [Self.item(Sample.gamma)], onto: .listBackground) == nil)
    }
}
