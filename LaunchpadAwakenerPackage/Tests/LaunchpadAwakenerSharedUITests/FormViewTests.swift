import AppKit
import Testing
@testable import LaunchpadAwakenerSharedUI

/// The grouped form's geometry, against what SwiftUI's grouped form measured on macOS 27.2: a row of
/// one line is 36 points tall, a row with a line under its title 52.5, and a section's header sits 10
/// points above its group. Nothing here goes on screen.
@Suite("Grouped form")
@MainActor
struct FormViewTests {
    private static let formWidth: CGFloat = 520

    private static func laidOut(_ formView: FormView) -> FormView {
        formView.frame = NSRect(x: 0, y: 0, width: formWidth, height: formView.fittingHeight(forWidth: formWidth))
        formView.layoutSubtreeIfNeeded()
        return formView
    }

    @Test("a row of one line is as tall as SwiftUI's: the line and 10 points above and below")
    func singleLineRowHeight() {
        let row = FormRowView(title: "Input method helper")
        _ = Self.laidOut(FormView(sections: [FormSectionView(rows: [row])]))
        #expect(row.frame.height == 36)
    }

    @Test("a row with a line under its title is as tall as SwiftUI's")
    func rowWithSubtitleHeight() {
        let row = FormRowView(title: "Launch at login", subtitle: "Starts with your Mac and stays in the menu bar.", accessoryView: NSSwitch())
        _ = Self.laidOut(FormView(sections: [FormSectionView(rows: [row])]))
        // Off screen the layout rounds to whole points; on a Retina screen the half point stays.
        #expect(abs(row.frame.height - 52.5) <= 0.5, "row height \(row.frame.height)")
    }

    @Test("the form is as tall as its sections: insets, header, the space under it, and the rows")
    func fittingHeight() {
        let section = FormSectionView(title: "General", symbolName: "gearshape.fill", rows: [
            FormRowView(title: "Privileged daemon"),
            FormRowView(title: "Input method helper"),
        ])
        // 20 + 16 (header) + 10 + 36 + 36 + 20
        #expect(FormView(sections: [section]).fittingHeight(forWidth: Self.formWidth) == 138)
    }

    @Test("a hidden row is left out of the height")
    func hiddenRowIsLeftOut() {
        let hiddenRow = FormRowView(title: "Turned off under System Settings › Login Items.")
        hiddenRow.isHidden = true
        let formView = FormView(sections: [FormSectionView(rows: [FormRowView(title: "Launch at login"), hiddenRow])])
        // 20 + 36 + 20, without a header
        #expect(formView.fittingHeight(forWidth: Self.formWidth) == 76)
    }

    @Test("only rows after the first visible one have a separator above them")
    func separatorsFollowVisibleRows() {
        let rows = [FormRowView(title: "Warning"), FormRowView(title: "Privileged daemon"), FormRowView(title: "Input method helper")]
        rows[0].isHidden = true
        let section = FormSectionView(rows: rows)
        _ = Self.laidOut(FormView(sections: [section]))
        #expect(rows.map(\.showsSeparator) == [false, false, true])
    }

    @Test("the separator is half as opaque as the system separator, in Dark Mode and in light", arguments: [NSAppearance.Name.darkAqua, .aqua])
    func separatorIsHalfTheSystemSeparator(appearanceName: NSAppearance.Name) throws {
        let appearance = try #require(NSAppearance(named: appearanceName))
        var systemSeparator: NSColor?
        var rowSeparator: NSColor?
        appearance.performAsCurrentDrawingAppearance {
            systemSeparator = NSColor.separatorColor.usingColorSpace(.sRGB)
            rowSeparator = FormRowView.separatorColor.usingColorSpace(.sRGB)
        }
        let resolvedSystemSeparator = try #require(systemSeparator)
        let resolvedRowSeparator = try #require(rowSeparator)
        #expect(resolvedRowSeparator.redComponent == resolvedSystemSeparator.redComponent)
        // 12% white in Dark Mode, so 6%; `withAlphaComponent(0.5)` alone would make it 50%.
        #expect(abs(resolvedRowSeparator.alphaComponent - resolvedSystemSeparator.alphaComponent / 2) < 0.001, "alpha \(resolvedRowSeparator.alphaComponent)")
    }
}

/// Where a window sized to its content opens.
@Suite("Content-sized window placement")
struct ContentSizedWindowPlacementTests {
    @Test("content that fits opens at its own height")
    func contentThatFits() {
        let placement = ContentSizedWindowPlacement(fittingContentHeight: 668, minimumContentHeight: 320, visibleFrameHeight: 1020, screenEdgeAllowance: 72)
        #expect(placement.contentHeight == 668)
    }

    @Test("content taller than the screen opens as tall as the visible area less the allowance")
    func contentTallerThanTheScreen() {
        let placement = ContentSizedWindowPlacement(fittingContentHeight: 1200, minimumContentHeight: 320, visibleFrameHeight: 960, screenEdgeAllowance: 72)
        #expect(placement.contentHeight == 888)
    }

    @Test("the minimum wins over a very short screen")
    func minimumWins() {
        let placement = ContentSizedWindowPlacement(fittingContentHeight: 668, minimumContentHeight: 320, visibleFrameHeight: 300, screenEdgeAllowance: 72)
        #expect(placement.contentHeight == 320)
    }
}
