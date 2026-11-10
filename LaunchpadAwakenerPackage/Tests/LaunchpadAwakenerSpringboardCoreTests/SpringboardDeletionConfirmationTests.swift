import CoreGraphics
import Foundation
@testable import LaunchpadAwakenerSpringboardCore
import QuartzCore
import Testing

/// The question asked before deleting an application when another process shows the popover, as macOS 15's
/// Dock had its ecap service show it: the springboard asks it, answers the keys itself, closes the popover
/// for every answer and when it goes, and draws its own where the popover cannot be shown.
@Suite("The deletion confirmation another process shows")
@MainActor
struct SpringboardDeletionConfirmationTests {
    /// Stands in for the popover: keeps what it was asked to show and how often it was shown and closed,
    /// and plays its buttons, its failure and its process going away.
    @MainActor
    private final class StandInConfirmation: SpringboardHostedDeletionConfirmation {
        let configuration: SpringboardHostedDeletionConfirmationConfiguration
        var answerHandler: ((SpringboardDeletionChoice) -> Void)?
        var presentationDidFail: (() -> Void)?
        var interruptionHandler: (() -> Void)?
        private(set) var presentCount = 0
        private(set) var dismissCount = 0

        init(configuration: SpringboardHostedDeletionConfirmationConfiguration) {
            self.configuration = configuration
        }

        func present() {
            presentCount += 1
        }

        func dismiss() {
            dismissCount += 1
        }
    }

    private static let screenHeight: CGFloat = 956

    private static let application = LaunchpadApplication(
        identifier: LaunchpadItemIdentifier(rowIdentifier: 51),
        title: "Calculator",
        bundleIdentifier: "com.example.calculator",
        bookmarkData: nil,
        legacyIconPNGData: nil,
        bundleURL: URL(fileURLWithPath: "/Applications/Calculator.app")
    )

    /// An interface on a 1470 × 956 display, an icon of `application` in its container, and the popovers it
    /// asks for; `isOnScreen` false leaves the interface without a place on screen.
    @MainActor
    private final class Fixture {
        let interface: SpringboardInterface
        let itemLayer = SpringboardItemLayer()
        private(set) var confirmations: [StandInConfirmation] = []

        init(isOnScreen: Bool = true) {
            let metrics = SpringboardMetrics(
                SpringboardMetrics.Input(
                    screenSize: CGSize(width: 1470, height: SpringboardDeletionConfirmationTests.screenHeight),
                    dockOrientation: .bottom,
                    dockThickness: 79,
                    notchHeight: 0,
                    rowCount: 5,
                    columnCount: 7,
                    zoomStyle: 0,
                    labelLineHeight: 16
                )
            )
            interface = SpringboardInterface(layout: .empty, metrics: metrics, scale: 2, rootLayer: CALayer(), applyEdit: { _ in })
            itemLayer.configure(with: .application(SpringboardDeletionConfirmationTests.application), metrics: interface.metrics, scale: 2)
            itemLayer.frame.origin = CGPoint(x: 600, y: 500)
            interface.containerLayer.addSublayer(itemLayer)
            if isOnScreen {
                // The display's top left is the screen's: the container is y-up from its bottom left.
                interface.screenTopLeft = { rectInContainer in
                    CGPoint(x: rectInContainer.minX, y: SpringboardDeletionConfirmationTests.screenHeight - rectInContainer.maxY)
                }
            }
            interface.makeHostedDeletionConfirmation = { [unowned self] configuration in
                let confirmation = StandInConfirmation(configuration: configuration)
                confirmations.append(confirmation)
                return confirmation
            }
        }

        var confirmation: StandInConfirmation? {
            confirmations.last
        }

        var drawnPanels: [SpringboardDeletionPanel] {
            interface.containerLayer.sublayers?.compactMap { $0 as? SpringboardDeletionPanel } ?? []
        }

        func askToDelete() {
            interface.presentDeletionPanel(for: itemLayer, context: .main)
        }

        func press(keyCode: Int64, characters: String, modifierFlags: CGEventFlags = []) {
            _ = interface.handleKeyDown(keyCode: keyCode, characters: characters, modifierFlags: modifierFlags)
        }
    }

    @Test("the popover is asked for with the icon, the words and the icon's centre on screen, and nothing is drawn")
    func asksTheHost() throws {
        let fixture = Fixture()
        defer { fixture.interface.tearDown() }

        fixture.askToDelete()

        let confirmation = try #require(fixture.confirmation)
        #expect(confirmation.presentCount == 1)
        #expect(fixture.confirmations.count == 1)
        #expect(fixture.drawnPanels.isEmpty)
        #expect(fixture.interface.deletionQuestion != nil)
        let imageLayer = fixture.itemLayer.imageLayer
        let iconFrame = imageLayer.convert(imageLayer.bounds, to: fixture.interface.containerLayer)
        #expect(confirmation.configuration.screenIconCenter == CGPoint(x: iconFrame.midX, y: Self.screenHeight - iconFrame.midY))
        #expect(confirmation.configuration.bundleURL == Self.application.bundleURL)
        #expect(confirmation.configuration.message == SpringboardDeletionStrings.message(forApplicationNamed: "Calculator"))
        #expect(confirmation.configuration.cancelButtonTitle == SpringboardDeletionStrings.cancel)
        #expect(confirmation.configuration.deleteButtonTitle == SpringboardDeletionStrings.delete)
    }

    @Test("one question at a time: a second close box while the popover is up asks nothing")
    func oneQuestionAtATime() {
        let fixture = Fixture()
        defer { fixture.interface.tearDown() }

        fixture.askToDelete()
        fixture.askToDelete()

        #expect(fixture.confirmations.count == 1)
    }

    @Test("Delete in the popover closes it and deletes the application")
    func popoverDelete() throws {
        let fixture = Fixture()
        defer { fixture.interface.tearDown() }
        fixture.askToDelete()
        let confirmation = try #require(fixture.confirmation)

        confirmation.answerHandler?(.delete)

        #expect(confirmation.dismissCount == 1)
        #expect(fixture.interface.deletionQuestion == nil)
        #expect(fixture.itemLayer.isBeingDeleted)
    }

    @Test("Cancel in the popover closes it and keeps the application")
    func popoverCancel() throws {
        let fixture = Fixture()
        defer { fixture.interface.tearDown() }
        fixture.askToDelete()
        let confirmation = try #require(fixture.confirmation)

        confirmation.answerHandler?(.cancel)

        #expect(confirmation.dismissCount == 1)
        #expect(fixture.interface.deletionQuestion == nil)
        #expect(!fixture.itemLayer.isBeingDeleted)
    }

    @Test("the springboard reads the keys itself: Return and Enter delete, Escape and Command-period cancel", arguments: [
        (SpringboardKeyCode.returnKey, "\r", CGEventFlags(), true),
        (SpringboardKeyCode.keypadEnter, "\u{3}", CGEventFlags(), true),
        (SpringboardKeyCode.escape, "\u{1B}", CGEventFlags(), false),
        (Int64(47), ".", CGEventFlags.maskCommand, false),
    ] as [(Int64, String, CGEventFlags, Bool)])
    func keys(keyCode: Int64, characters: String, modifierFlags: CGEventFlags, deletes: Bool) throws {
        let fixture = Fixture()
        defer { fixture.interface.tearDown() }
        fixture.askToDelete()
        let confirmation = try #require(fixture.confirmation)

        fixture.press(keyCode: keyCode, characters: characters, modifierFlags: modifierFlags)

        #expect(confirmation.dismissCount == 1)
        #expect(fixture.interface.deletionQuestion == nil)
        #expect(fixture.itemLayer.isBeingDeleted == deletes)
    }

    @Test("other keys and clicks anywhere leave the popover up")
    func otherInputLeavesItUp() throws {
        let fixture = Fixture()
        defer { fixture.interface.tearDown() }
        fixture.askToDelete()
        let confirmation = try #require(fixture.confirmation)

        fixture.press(keyCode: 0, characters: "a")
        _ = fixture.interface.handleMouseDown(at: CGPoint(x: 20, y: 20), timestamp: 0)
        _ = fixture.interface.handleMouseUp(at: CGPoint(x: 20, y: 20), timestamp: 0)

        #expect(confirmation.dismissCount == 0)
        #expect(fixture.interface.deletionQuestion != nil)
    }

    @Test("a button pressed after the question was answered is not taken")
    func lateButtonIgnored() throws {
        let fixture = Fixture()
        defer { fixture.interface.tearDown() }
        fixture.askToDelete()
        let confirmation = try #require(fixture.confirmation)
        fixture.press(keyCode: SpringboardKeyCode.escape, characters: "\u{1B}")

        confirmation.answerHandler?(.delete)

        #expect(!fixture.itemLayer.isBeingDeleted)
        #expect(confirmation.dismissCount == 1)
    }

    @Test("a popover that cannot be shown leaves the springboard to draw its own, which then answers")
    func fallsBackToDrawing() throws {
        let fixture = Fixture()
        defer { fixture.interface.tearDown() }
        fixture.askToDelete()
        let confirmation = try #require(fixture.confirmation)

        confirmation.presentationDidFail?()

        #expect(fixture.drawnPanels.count == 1)
        #expect(fixture.interface.deletionQuestion != nil)
        fixture.press(keyCode: SpringboardKeyCode.returnKey, characters: "\r")
        #expect(fixture.drawnPanels.isEmpty)
        #expect(fixture.itemLayer.isBeingDeleted)
        #expect(confirmation.dismissCount == 0)
    }

    @Test("the popover's process going away ends the question without deleting")
    func interruptionCancels() throws {
        let fixture = Fixture()
        defer { fixture.interface.tearDown() }
        fixture.askToDelete()
        let confirmation = try #require(fixture.confirmation)

        confirmation.interruptionHandler?()

        #expect(fixture.interface.deletionQuestion == nil)
        #expect(!fixture.itemLayer.isBeingDeleted)
        #expect(fixture.drawnPanels.isEmpty)
    }

    @Test("Launchpad going takes the popover down, as Cancel")
    func hidingCancels() throws {
        let fixture = Fixture()
        defer { fixture.interface.tearDown() }
        fixture.askToDelete()
        let confirmation = try #require(fixture.confirmation)

        fixture.interface.prepareForHiding()

        #expect(confirmation.dismissCount == 1)
        #expect(fixture.interface.deletionQuestion == nil)
        #expect(!fixture.itemLayer.isBeingDeleted)
    }

    @Test("without a place on screen, the springboard draws its own and asks no one")
    func noPlaceOnScreen() {
        let fixture = Fixture(isOnScreen: false)
        defer { fixture.interface.tearDown() }

        fixture.askToDelete()

        #expect(fixture.confirmations.isEmpty)
        #expect(fixture.drawnPanels.count == 1)
    }
}
