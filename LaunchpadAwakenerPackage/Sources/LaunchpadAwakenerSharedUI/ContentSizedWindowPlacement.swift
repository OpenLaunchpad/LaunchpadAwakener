import CoreGraphics

/// How tall a window sized to its content opens: as tall as the content, never taller than the screen's
/// visible area less an allowance, and never shorter than its minimum.
///
/// The visible area already leaves out the menu bar and the Dock. The allowance covers what the
/// content height does not include — the title bar — and a margin; without the cap a window sized to its
/// content alone reached down behind the Dock on the test MacBook.
public struct ContentSizedWindowPlacement: Equatable, Sendable {
    /// The height of the window's content view.
    public let contentHeight: CGFloat

    public init(fittingContentHeight: CGFloat, minimumContentHeight: CGFloat, visibleFrameHeight: CGFloat, screenEdgeAllowance: CGFloat) {
        contentHeight = max(minimumContentHeight, min(fittingContentHeight, visibleFrameHeight - screenEdgeAllowance))
    }
}
