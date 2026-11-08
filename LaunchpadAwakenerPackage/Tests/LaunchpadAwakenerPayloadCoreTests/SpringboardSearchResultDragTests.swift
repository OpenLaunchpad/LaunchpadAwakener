import Foundation
import LaunchpadAwakenerPayloadCore
import Testing

/// Dragging a search result, by macOS 15.5's rule (`sub_1000B4388`, 15.5 `0x1000B4388`): the drag starts
/// from where the application really is — on a page, or in a folder on one — and the application joins the
/// page shown before the search, after that page's other items.
@Suite("Dragging a search result")
struct SpringboardSearchResultDragTests {
    private static func identifier(_ rowIdentifier: Int64) -> LaunchpadItemIdentifier {
        LaunchpadItemIdentifier(rowIdentifier: rowIdentifier)
    }

    private static func application(_ rowIdentifier: Int64) -> LaunchpadApplication {
        LaunchpadApplication(
            identifier: identifier(rowIdentifier),
            title: "Application \(rowIdentifier)",
            bundleIdentifier: "com.example.\(rowIdentifier)",
            bookmarkData: nil,
            legacyIconPNGData: nil
        )
    }

    private static let layout = LaunchpadLayout(pages: [
        LaunchpadPage(identifier: identifier(1), items: [
            .application(application(10)),
            .folder(LaunchpadFolder(
                identifier: identifier(11),
                title: "Tools",
                pages: [
                    LaunchpadFolderPage(identifier: identifier(12), applications: [application(13), application(14)]),
                    LaunchpadFolderPage(identifier: identifier(15), applications: [application(16)]),
                ]
            )),
        ]),
        LaunchpadPage(identifier: identifier(2), items: [
            .application(application(20)),
            .application(application(21)),
        ]),
    ])

    @Test("an application on a page is found there")
    func applicationOnPage() {
        #expect(SpringboardDragging.location(of: Self.identifier(21), in: Self.layout) == .mainPage(pageIndex: 1, itemIndex: 1))
    }

    @Test("an application in a folder is found in the folder, which is found on its page")
    func applicationInFolder() {
        #expect(
            SpringboardDragging.location(of: Self.identifier(16), in: Self.layout)
                == .folder(Self.identifier(11), mainPageIndex: 0, pageIndex: 1, itemIndex: 0)
        )
    }

    @Test("neither a folder nor an application missing from the layout is found")
    func nothingElseIsFound() {
        #expect(SpringboardDragging.location(of: Self.identifier(11), in: Self.layout) == nil)
        #expect(SpringboardDragging.location(of: Self.identifier(99), in: Self.layout) == nil)
    }

    /// The second page's items, each with a stand-in for its layer.
    private static let secondPageEntries = layout.pages[1].items.map { (item: $0, layer: "layer of \($0.identifier)") }

    @Test("the result goes after the page's other items, leaving its own place if it was on that page")
    func resultJoinsPage() {
        let fromSamePage = SpringboardDragging.arrangement(joining: .application(Self.application(20)), page: Self.secondPageEntries, capacity: 35)
        let fromFolder = SpringboardDragging.arrangement(joining: .application(Self.application(13)), page: Self.secondPageEntries, capacity: 35)

        #expect(fromSamePage.items.map(\.identifier) == [Self.identifier(21), Self.identifier(20)])
        #expect(fromSamePage.layers == ["layer of #21", nil])
        #expect(fromSamePage.index == 1)
        #expect(fromFolder.items.map(\.identifier) == [Self.identifier(20), Self.identifier(21), Self.identifier(13)])
        #expect(fromFolder.layers == ["layer of #20", "layer of #21", nil])
        #expect(fromFolder.index == 2)
    }

    @Test("on a full page the result takes the last cell, whose item spills over on the drop")
    func resultJoinsFullPage() {
        let joined = SpringboardDragging.arrangement(joining: .application(Self.application(13)), page: Self.secondPageEntries, capacity: 2)

        #expect(joined.items.map(\.identifier) == [Self.identifier(20), Self.identifier(13), Self.identifier(21)])
        #expect(joined.layers == ["layer of #20", nil, "layer of #21"])
        #expect(joined.index == 1)
    }
}
