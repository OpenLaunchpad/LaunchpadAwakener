import AppKit
import LaunchpadAwakenerAppCore

extension StatusTint {
    /// The colour the interface draws this tint in: the banner, a status dot, a line of text.
    var color: NSColor {
        switch self {
        case .progress: .systemBlue
        case .positive: .systemGreen
        case .caution: .systemOrange
        case .critical: .systemRed
        case .paused: .systemIndigo
        case .neutral: .secondaryLabelColor
        }
    }
}
