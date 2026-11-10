import Foundation

// The deletion confirmation's part of the messages between the payload and the text input helper. The helper
// shows it the way macOS 15's Dock had its `com.apple.dock.ecap` service show it: a popover whose own window
// goes on screen over Launchpad's.

/// The confirmation the payload asks the helper to show before deleting an application.
public struct DeletionConfirmationConfiguration: Codable, Sendable, Equatable {
    /// The icon as Launchpad draws it, as PNG, which is how 15's Dock sent it. Nil leaves the helper the
    /// application bundle's own icon.
    public var iconPNGData: Data?
    /// The application's bundle, for its icon when no image comes along.
    public var bundlePath: String
    public var message: String
    public var cancelButtonTitle: String
    public var deleteButtonTitle: String
    /// The icon's centre on screen, in points from the top left of the main display. The popover hangs
    /// below it.
    public var iconCenterX: Double
    public var iconCenterY: Double

    public init(
        iconPNGData: Data?,
        bundlePath: String,
        message: String,
        cancelButtonTitle: String,
        deleteButtonTitle: String,
        iconCenterX: Double,
        iconCenterY: Double
    ) {
        self.iconPNGData = iconPNGData
        self.bundlePath = bundlePath
        self.message = message
        self.cancelButtonTitle = cancelButtonTitle
        self.deleteButtonTitle = deleteButtonTitle
        self.iconCenterX = iconCenterX
        self.iconCenterY = iconCenterY
    }
}

/// The helper's answer to ``TextInputRequest/presentDeletionConfirmation(_:)``.
public struct DeletionConfirmationPresentation: Codable, Sendable, Equatable {
    /// Whether the popover is on screen. When it is not, the payload asks with a confirmation of its own.
    public var isShown: Bool

    public init(isShown: Bool) {
        self.isShown = isShown
    }
}

/// The button pressed in the deletion confirmation.
public enum DeletionConfirmationAnswer: String, Codable, Sendable, Equatable {
    case delete
    case cancel
}
