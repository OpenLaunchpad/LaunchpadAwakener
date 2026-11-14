import Foundation
import HelperCommunication

/// What the app tells the payload about the icon on the Dock's Apps tile.
///
/// The app is the only party that decides this: it owns the preference and it knows where its own
/// bundle is, so the payload neither reads a preference domain of the app's nor guesses an install
/// location. A payload that is never told keeps the Dock's own icon.

/// Asks the payload to put `iconPath` on the Dock's Apps tile, or to give the tile back to the Dock.
public struct DockAppsIconRequest: Codable, Sendable, Request {
    public typealias Response = DockAppsIconReply

    public static let identifier = "com.MxIris.LaunchpadAwakener.DockAppsIcon"

    public let isEnabled: Bool

    /// Absolute path of the image to use, sent whether or not it is wanted right now.
    ///
    /// Always carried, so that switching the override on needs no second request and a payload that
    /// reconnects has the path from the first thing it is told.
    public let iconPath: String

    public init(isEnabled: Bool, iconPath: String) {
        self.isEnabled = isEnabled
        self.iconPath = iconPath
    }
}

public enum DockAppsIconReply: Codable, Sendable, Equatable {
    /// Done, and this is how many Apps tiles the Dock turned out to have.
    ///
    /// Zero is a normal answer rather than a failure: someone who removed Apps from their Dock has no
    /// tile to change, and the override will apply by itself if they put it back.
    case applied(appsTileCount: Int)

    /// Nothing was done, because this payload has no hook on the Dock's icon path — the Dock's method
    /// no longer matches what the payload recorded for it. The reason is for the control panel to show.
    case unsupported(reason: String)
}
