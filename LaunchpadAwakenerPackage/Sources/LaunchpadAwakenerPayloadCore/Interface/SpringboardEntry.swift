import Foundation

/// What a request to open Apps — the Launchpad key, a hot corner, the Apps icon in the Dock — does to the
/// springboard.
///
/// macOS 15's Launchpad icon toggled Launchpad, while a click on any other icon in the Dock closed
/// Launchpad before that icon acted (15.5 `0x10002CE10`, which spared only the Launchpad docklet). 27.2's
/// Dock does not tell this payload which icon a click hit, so every click on the Dock closes the
/// springboard. The Apps icon's own request follows that click within a moment —
/// `-[DOCKFileTile doAction:fromKeyboard:]` hands it to the main queue through `-[WVExpose exitAndDoWork:]`
/// (27.2 `0x100015028`, `0x1001DD51C`) — and is told apart by arriving within ``dockClickWindow``; without
/// that, the click that closed the springboard would open it again at once.
package enum SpringboardEntry {
    package enum Response: Equatable, Sendable {
        case show
        case hide
        /// The request comes from the click that has just closed the springboard: the Apps icon's.
        case stayHidden
    }

    /// How long after a click on the Dock closed the springboard a request still counts as that click's.
    package static let dockClickWindow: Duration = .milliseconds(500)

    /// - Parameter sinceDockClickDismissal: How long ago a click on the Dock last closed the springboard;
    ///   nil when none has since the last request.
    package static func response(isVisible: Bool, sinceDockClickDismissal: Duration?) -> Response {
        if isVisible {
            return .hide
        }
        if let sinceDockClickDismissal, sinceDockClickDismissal < dockClickWindow {
            return .stayHidden
        }
        return .show
    }
}
