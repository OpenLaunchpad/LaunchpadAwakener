import AppKit
import Testing
@testable import LaunchpadAwakenerAppUI

/// The bar under the organizer's list, laid out in a window that is never ordered front.
@Suite("Organizer status bar")
@MainActor
struct OrganizerStatusBarTests {
    @Test("a short message takes the bar's width and stays on one line")
    func shortMessageStaysOnOneLine() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 200), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.animationBehavior = .none
        defer { window.close() }
        let containerView = NSView()
        window.contentView = containerView
        let statusBar = OrganizerStatusBarView()
        statusBar.translatesAutoresizingMaskIntoConstraints = false
        containerView.addSubview(statusBar)
        NSLayoutConstraint.activate([
            statusBar.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            statusBar.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            statusBar.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
        ])
        // Laid out once hidden and empty, as when the window opens, before any edit is sent.
        window.layoutIfNeeded()

        statusBar.show(isApplying: true, errorDescription: nil)
        window.layoutIfNeeded()

        let lineHeight = NSLayoutManager().defaultLineHeight(for: .preferredFont(forTextStyle: .callout))
        // One line and the bar's top and bottom margins of 8 points; a second line would add another.
        #expect(statusBar.frame.height < lineHeight * 1.5 + 16, "the bar is \(statusBar.frame.height) points tall")
    }
}
