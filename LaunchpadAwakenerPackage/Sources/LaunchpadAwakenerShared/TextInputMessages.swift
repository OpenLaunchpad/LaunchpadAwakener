import Foundation

// The messages between the payload and the text input helper. Both sides link this module, so the wire
// contract is one file rather than something to reconstruct from two implementations. They travel as XPC
// dictionaries, encoded by the XPC framework's own `Codable` support.

/// What the payload asks the text input helper. One type for every request, because the helper reads each
/// session through one handler.
public enum TextInputRequest: Codable, Sendable, Equatable {
    /// Set the field up and host it; answered with ``TextInputHosting``.
    case begin(TextInputFieldConfiguration)
    /// Replace the text, the selection going to its end.
    case setString(String)
    /// The field gained or lost the focus; without it the field shows no caret, as 15's did not.
    case setFocus(Bool)
    /// Commit any composing text and let the field go; answered with ``TextInputEnding``.
    case end
}

/// The field the payload asks the helper to host.
public struct TextInputFieldConfiguration: Codable, Sendable, Equatable {
    public var isSearchField: Bool
    public var string: String
    /// Whether the whole string starts selected, as 15's rename field did.
    public var selectsAll: Bool
    public var hasFocus: Bool
    public var width: Double
    public var height: Double
    public var fontSize: Double
    /// The text area's top-left corner on screen, in points from the top left of the main display; the
    /// candidate window is placed from it.
    public var screenLeft: Double
    public var screenTop: Double

    public init(
        isSearchField: Bool,
        string: String,
        selectsAll: Bool,
        hasFocus: Bool,
        width: Double,
        height: Double,
        fontSize: Double,
        screenLeft: Double,
        screenTop: Double
    ) {
        self.isSearchField = isSearchField
        self.string = string
        self.selectsAll = selectsAll
        self.hasFocus = hasFocus
        self.width = width
        self.height = height
        self.fontSize = fontSize
        self.screenLeft = screenLeft
        self.screenTop = screenTop
    }
}

/// The helper's answer to ``TextInputRequest/begin(_:)``: what showing the hosted field takes, and where
/// its events go. A zero context identifier means the helper could not host the field.
public struct TextInputHosting: Codable, Sendable, Equatable {
    /// The layer-hosting context a `CALayerHost` in the Dock shows.
    public var contextIdentifier: UInt32
    /// The helper's process, which the Dock posts the field's keys and clicks to.
    public var processIdentifier: Int32
    /// The window the posted events are marked with.
    public var windowNumber: Int

    public init(contextIdentifier: UInt32, processIdentifier: Int32, windowNumber: Int) {
        self.contextIdentifier = contextIdentifier
        self.processIdentifier = processIdentifier
        self.windowNumber = windowNumber
    }

    /// The answer when the helper cannot host the field.
    public static let unavailable = TextInputHosting(contextIdentifier: 0, processIdentifier: 0, windowNumber: 0)
}

/// The helper's answer to ``TextInputRequest/end``.
public struct TextInputEnding: Codable, Sendable, Equatable {
    /// The final text, composing text included, for a rename that ended while text was composing. Nil when
    /// the helper never set this field up, as the text left in it is then another field's.
    public var string: String?

    public init(string: String?) {
        self.string = string
    }
}

/// Helper to payload: the field's text or its composing state changed.
public struct TextInputChange: Codable, Sendable, Equatable {
    /// The text without the part still composing.
    public var string: String
    public var hasMarkedText: Bool
    /// Return, Enter or Escape ended the editing: 15's rename field kept the text on all three.
    public var isEditingComplete: Bool

    public init(string: String, hasMarkedText: Bool, isEditingComplete: Bool) {
        self.string = string
        self.hasMarkedText = hasMarkedText
        self.isEditingComplete = isEditingComplete
    }
}
