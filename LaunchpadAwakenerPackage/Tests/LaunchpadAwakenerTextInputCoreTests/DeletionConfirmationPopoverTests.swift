import AppKit
import LaunchpadAwakenerShared
import Testing
@testable import LaunchpadAwakenerTextInputCore

/// The deletion confirmation the helper shows, by the rules of macOS 15's `com.apple.dock.ecap` service:
/// where the anchor goes, what the popover points at, the level it is raised to, and the content laid out
/// as the service's nib. Only views are made here, never a window.
@Suite("The deletion confirmation's popover")
@MainActor
struct DeletionConfirmationPopoverTests {
    private static let configuration = DeletionConfirmationConfiguration(
        iconPNGData: nil,
        bundlePath: "/Applications/Calculator.app",
        message: "确定要删除应用程序“可删测试”吗？",
        cancelButtonTitle: "取消",
        deleteButtonTitle: "删除",
        iconCenterX: 742.5,
        iconCenterY: 318
    )

    @Test("the anchor is 16 × 16 on the icon's centre, turned into AppKit's coordinates from the bottom left")
    func anchorFrame() {
        let frame = DeletionConfirmationPopover.anchorFrame(forIconCenter: CGPoint(x: 742.5, y: 318), zeroScreenHeight: 956)

        #expect(frame == NSRect(x: 734.5, y: 630, width: 16, height: 16))
        #expect(frame.midX == 742.5 && frame.midY == 956 - 318)
    }

    @Test("the popover points at 20 × 20 on the anchor's centre, as 15 got by insetting the anchor by −2")
    func positioningRect() {
        #expect(DeletionConfirmationPopover.positioningRect == NSRect(x: -2, y: -2, width: 20, height: 20))
    }

    @Test("the popover's window goes above Launchpad's window and the Dock's, at 15's level")
    func windowLevel() {
        #expect(DeletionConfirmationPopover.windowLevel.rawValue == 106)
        #expect(DeletionConfirmationPopover.windowLevel.rawValue > 29)
    }

    /// The popover's window copies whether it is a nonactivating panel from its anchor's window, and in a
    /// process that is not the active application only a nonactivating window becomes key — the key window
    /// alone draws Delete as the default button. 26.6's AppKit: `-[NSPopover showRelativeToRect:ofView:preferredEdge:]`
    /// `0x184C67550`, `-[NSWindow _changeKeyAndMainLimitedOK:]` `0x184AE7E54`.
    @Test("the anchor is a nonactivating panel that stays up when the process deactivates, shows nothing and lets clicks through")
    func anchorIsNonactivatingPanel() throws {
        let anchorWindow = DeletionConfirmationPopover.makeAnchorWindow()
        defer { anchorWindow.close() }

        let panel = try #require(anchorWindow as? NSPanel)
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(!panel.hidesOnDeactivate)
        #expect(panel.ignoresMouseEvents)
        #expect(!panel.isOpaque && !panel.hasShadow)
        #expect(panel.level == DeletionConfirmationPopover.windowLevel)
        #expect(!panel.isVisible)
    }

    @Test("the content is 400 wide and at least 84 high, the icon 64 at 10 from the top left, the question beside it")
    func contentLayout() throws {
        let controller = DeletionConfirmationViewController()

        controller.configure(with: Self.configuration)

        let view = controller.view
        #expect(view.frame.width == 400)
        #expect(view.frame.height >= 84)
        #expect(controller.preferredContentSize == view.frame.size)
        #expect(controller.iconView.frame == NSRect(x: 10, y: view.frame.height - 10 - 64, width: 64, height: 64))
        let messageFrame = controller.messageField.alignmentRect(forFrame: controller.messageField.frame)
        #expect(abs(messageFrame.minX - 84) < 0.001)
        #expect(abs(messageFrame.maxY - (view.frame.height - 10)) < 0.001)
        // Auto Layout's arithmetic leaves the right edge a hair off a whole point.
        #expect(abs(messageFrame.maxX - (400 - 12)) < 0.001, "message \(messageFrame) in \(view.frame)")
        #expect(controller.messageField.stringValue == Self.configuration.message)
        #expect(controller.messageField.font?.pointSize == 13)
        #expect(controller.iconView.image != nil)
    }

    @Test("Cancel and Delete sit at the bottom right, Delete last and the default button")
    func buttons() {
        let controller = DeletionConfirmationViewController()

        controller.configure(with: Self.configuration)

        let cancelFrame = controller.cancelButton.alignmentRect(forFrame: controller.cancelButton.frame)
        let deleteFrame = controller.deleteButton.alignmentRect(forFrame: controller.deleteButton.frame)
        #expect(controller.cancelButton.title == "取消")
        #expect(controller.deleteButton.title == "删除")
        // Auto Layout's arithmetic leaves the edges a hair off whole points.
        #expect(abs(deleteFrame.maxX - (400 - 12)) < 0.001, "Delete \(deleteFrame) in \(controller.view.frame)")
        #expect(abs(deleteFrame.minY - 10) < 0.001 && abs(cancelFrame.minY - 10) < 0.001)
        #expect(abs(cancelFrame.maxX - (deleteFrame.minX - 10)) < 0.001, "Cancel \(cancelFrame), Delete \(deleteFrame)")
        #expect(controller.deleteButton.keyEquivalent == "\r")
        #expect(controller.cancelButton.keyEquivalent.isEmpty)
    }

    @Test("a long question makes the content taller, the buttons staying at the bottom")
    func longQuestion() {
        var configuration = Self.configuration
        configuration.message = String(repeating: "确定要删除应用程序“可删测试”吗？", count: 8)
        let controller = DeletionConfirmationViewController()

        controller.configure(with: configuration)

        #expect(controller.view.frame.height > 84)
        #expect(abs(controller.deleteButton.alignmentRect(forFrame: controller.deleteButton.frame).minY - 10) < 0.001)
    }

    @Test("the buttons say which was pressed, and nothing else")
    func buttonsAnswer() {
        let controller = DeletionConfirmationViewController()
        controller.configure(with: Self.configuration)
        var answers: [DeletionConfirmationAnswer] = []
        controller.answerHandler = { answer in
            answers.append(answer)
        }

        controller.deleteButton.performClick(nil)
        controller.cancelButton.performClick(nil)

        #expect(answers == [.delete, .cancel])
    }

    @Test("the icon the Dock sends is the one shown")
    func iconFromTheDock() throws {
        let representation = try #require(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: 48,
            pixelsHigh: 48,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        var configuration = Self.configuration
        configuration.iconPNGData = try #require(representation.representation(using: .png, properties: [:]))
        let controller = DeletionConfirmationViewController()

        controller.configure(with: configuration)

        let image = try #require(controller.iconView.image)
        #expect(image.representations.first?.pixelsWide == 48)
    }

    @Test("without an image, or with one that does not decode, the bundle's own icon is shown")
    func iconFallsBackToTheBundle() {
        var configuration = Self.configuration
        configuration.bundlePath = "/System/Applications/Calculator.app"
        configuration.iconPNGData = Data([0x00, 0x01, 0x02])
        let controller = DeletionConfirmationViewController()

        controller.configure(with: configuration)

        #expect(controller.iconView.image != nil)
    }
}
