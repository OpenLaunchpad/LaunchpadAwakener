import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerPayloadCore
import QuartzCore
import Testing
import TestingSupport

/// Regressions found reviewing the delete and blue-dot work.
@Suite("Deleting and the blue dot: review regressions")
@MainActor
struct SpringboardDeletionReviewTests {
    private static let application = LaunchpadApplication(
        identifier: LaunchpadItemIdentifier(rowIdentifier: 51),
        title: "Calculator",
        bundleIdentifier: "com.example.calculator",
        bookmarkData: nil,
        legacyIconPNGData: nil,
        bundleURL: URL(fileURLWithPath: "/Applications/Calculator.app")
    )

    private static func makeInterface() -> SpringboardInterface {
        let metrics = SpringboardMetrics(
            SpringboardMetrics.Input(
                screenSize: CGSize(width: 1470, height: 956),
                dockOrientation: .bottom,
                dockThickness: 79,
                notchHeight: 0,
                rowCount: 5,
                columnCount: 7,
                zoomStyle: 0,
                labelLineHeight: 16
            )
        )
        return SpringboardInterface(layout: .empty, metrics: metrics, scale: 2, rootLayer: CALayer(), applyEdit: { _ in })
    }

    @Test("an icon confirmed for deletion stops taking presses until the delete is over")
    func confirmedIconIsBeingDeleted() throws {
        let interface = Self.makeInterface()
        defer { interface.tearDown() }
        let itemLayer = SpringboardItemLayer()
        itemLayer.configure(with: .application(Self.application), metrics: interface.metrics, scale: 2)
        interface.presentDeletionPanel(for: itemLayer, context: .main)
        try #require(interface.deletionPanel != nil)

        interface.answerDeletionPanel(.delete)

        #expect(itemLayer.isBeingDeleted)
    }

    @Test("an application already taken out by reconciliation is no error, and its folder still dissolves")
    func removingAnApplicationAlreadyGone() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))
            let pageIdentifier = try store.appendPage(to: store.rootIdentifier)
            let folder = try store.appendFolder(titled: "Tools", to: pageIdentifier)
            let beta = try store.appendApplication(LaunchpadApplicationRecord(title: "Beta", bundleIdentifier: "com.example.beta"), to: folder.firstPage)
            try store.appendApplication(LaunchpadApplicationRecord(title: "Gamma", bundleIdentifier: "com.example.gamma"), to: folder.firstPage)
            // The bundle went, and reconciliation removed the item before the edit arrived.
            try store.removeItem(beta)

            try store.removeApplication(beta, fromFolder: folder.folder, itemsPerPage: 35)

            #expect(try store.layout().pages.map { $0.items.map(\.title) } == [["Gamma"]])
        }
    }

    @Test("only marked applications with a bundle are asked about, and those launched come back")
    func launchedMarkedApplications() {
        let marked = LaunchpadApplication(
            identifier: LaunchpadItemIdentifier(rowIdentifier: 1),
            title: "Alpha",
            bundleIdentifier: "com.example.alpha",
            bookmarkData: nil,
            legacyIconPNGData: nil,
            bundleURL: URL(fileURLWithPath: "/Applications/Alpha.app"),
            isRecentlyAdded: true
        )
        let unmarked = LaunchpadApplication(
            identifier: LaunchpadItemIdentifier(rowIdentifier: 2),
            title: "Beta",
            bundleIdentifier: "com.example.beta",
            bookmarkData: nil,
            legacyIconPNGData: nil,
            bundleURL: URL(fileURLWithPath: "/Applications/Beta.app")
        )
        var askedPaths: [String] = []
        let launched = RecentlyAddedApplications.launchedBundleIdentifiers(among: [marked, unmarked]) { bundleURL in
            askedPaths.append(bundleURL.path)
            return true
        }
        #expect(launched == ["com.example.alpha"])
        #expect(askedPaths == ["/Applications/Alpha.app"])
    }
}
