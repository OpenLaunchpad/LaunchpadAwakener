import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import Testing
import TestingSupport

/// Deleting an application in jiggle mode, by macOS 15.5's rules: the close box
/// (`-[ECSBItemLayer _closeboxFrame]`, `0x1000621D0`), the confirmation popover drawn by the
/// `com.apple.dock.ecap` service (400 × 84 under the icon, Return deletes, Escape and Command-period
/// cancel), and the layout once the application is gone.
@Suite("Deleting applications")
@MainActor
struct SpringboardDeletionTests {
    @Test("the close box is centred 10 % in from the image's top left corner")
    func closeBoxFrame() {
        let frame = SpringboardItemLayer.closeBoxFrame(
            imageFrame: CGRect(x: 36, y: 63, width: 120, height: 120),
            closeBoxSize: CGSize(width: 28, height: 28)
        )
        #expect(frame == CGRect(x: 34, y: 157, width: 28, height: 28))
    }

    @Test("the popover hangs under the icon, its arrow pointing at the icon's centre")
    func panelUnderIcon() {
        let layout = SpringboardDeletionPanel.Layout(iconCenter: CGPoint(x: 700, y: 600), containerBounds: CGRect(x: 0, y: 0, width: 1739, height: 1080))
        #expect(layout.bodyFrame.size == CGSize(width: 400, height: 84))
        #expect(layout.bodyFrame.midX == 700)
        #expect(layout.arrowTip == CGPoint(x: 700, y: 590))
        #expect(layout.bodyFrame.maxY == 590 - SpringboardDeletionPanel.arrowHeight)
    }

    @Test("near the edge of the screen the popover stays on it, the arrow still on the icon")
    func panelClampedToScreen() {
        let layout = SpringboardDeletionPanel.Layout(iconCenter: CGPoint(x: 120, y: 600), containerBounds: CGRect(x: 0, y: 0, width: 1739, height: 1080))
        #expect(layout.bodyFrame.minX == SpringboardDeletionPanel.screenMargin)
        #expect(layout.arrowTip.x == 120)
    }

    @Test(
        "Return and Enter delete; Escape and Command-period cancel; other keys do nothing",
        arguments: [
            (SpringboardKeyCode.returnKey, "\r", false, SpringboardDeletionPanel.Choice.delete),
            (SpringboardKeyCode.keypadEnter, "\u{3}", false, .delete),
            (SpringboardKeyCode.escape, "\u{1B}", false, .cancel),
            (Int64(47), ".", true, .cancel),
            (Int64(47), ".", false, nil),
            (Int64(0), "a", false, nil),
        ] as [(Int64, String, Bool, SpringboardDeletionPanel.Choice?)]
    )
    func keys(keyCode: Int64, characters: String, hasCommand: Bool, expectedChoice: SpringboardDeletionPanel.Choice?) {
        #expect(SpringboardDeletionPanel.Choice(keyCode: keyCode, characters: characters, hasCommand: hasCommand) == expectedChoice)
    }

    @Test("a deleted application leaves its page, and a folder left with one application dissolves")
    func removingFromStore() throws {
        try withTemporaryDirectory { directoryURL in
            let store = try LaunchpadStore(databaseURL: directoryURL.appendingPathComponent("Launchpad.db"))
            let pageIdentifier = try store.appendPage(to: store.rootIdentifier)
            let alpha = try store.appendApplication(LaunchpadApplicationRecord(title: "Alpha", bundleIdentifier: "com.example.alpha"), to: pageIdentifier)
            let folder = try store.appendFolder(titled: "Tools", to: pageIdentifier)
            let beta = try store.appendApplication(LaunchpadApplicationRecord(title: "Beta", bundleIdentifier: "com.example.beta"), to: folder.firstPage)
            try store.appendApplication(LaunchpadApplicationRecord(title: "Gamma", bundleIdentifier: "com.example.gamma"), to: folder.firstPage)
            try store.appendApplication(LaunchpadApplicationRecord(title: "Delta", bundleIdentifier: "com.example.delta"), to: pageIdentifier)

            try store.removeApplication(alpha, fromFolder: nil, itemsPerPage: 35)
            #expect(try store.layout().pages.map { $0.items.map(\.title) } == [["Tools", "Delta"]])

            try store.removeApplication(beta, fromFolder: folder.folder, itemsPerPage: 35)
            #expect(try store.layout().pages.map { $0.items.map(\.title) } == [["Gamma", "Delta"]])
        }
    }
}
