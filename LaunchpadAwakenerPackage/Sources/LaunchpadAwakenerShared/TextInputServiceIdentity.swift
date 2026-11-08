import Foundation

/// Names shared by the payload and the text input helper, the LaunchAgent that hosts the springboard's
/// text fields so that input methods work in them, as macOS 15's `com.apple.dock.ecti` service did.
///
/// The matching build setting is `TEXT_INPUT_SERVICE_NAME`; the two must agree, as the daemon's
/// `INJECTION_SERVICE_NAME` and ``InjectionServiceIdentity/machServiceName`` must.
public enum TextInputServiceIdentity {
    /// Mach service the helper's LaunchAgent publishes and the payload connects to. Debug and Release
    /// differ so that a development build and an installed one each have their own helper.
    public static let machServiceName: String = {
        #if DEBUG
        "com.MxIris.LaunchpadAwakener.textinput.debug"
        #else
        "com.MxIris.LaunchpadAwakener.textinput"
        #endif
    }()

    /// File name of the LaunchAgent's property list inside `Contents/Library/LaunchAgents/`, which
    /// `SMAppService.agent(plistName:)` takes; the build generates the file under this name.
    public static var agentPropertyListName: String { "\(machServiceName).plist" }

    /// Keys of the XPC messages between the payload and the helper.
    public enum MessageKey {
        /// Which message it is: one of ``Request``.
        public static let request = "request"
        public static let isSearchField = "isSearchField"
        public static let string = "string"
        /// Whether the whole string starts selected, as 15's rename field did.
        public static let selectsAll = "selectsAll"
        public static let width = "width"
        public static let height = "height"
        public static let fontSize = "fontSize"
        /// The text area's top-left corner on screen, in points from the top left of the main display;
        /// the candidate window is placed from it.
        public static let screenLeft = "screenLeft"
        public static let screenTop = "screenTop"
        public static let contextIdentifier = "contextIdentifier"
        public static let processIdentifier = "processIdentifier"
        public static let windowNumber = "windowNumber"
        public static let hasMarkedText = "hasMarkedText"
        /// Return, Enter or Escape ended the editing: 15's rename field kept the text on all three.
        public static let isEditingComplete = "isEditingComplete"
    }

    /// Values of ``MessageKey/request``.
    public enum Request {
        /// Payload to helper: set the field up and host it; the reply carries what showing it takes.
        public static let begin = "begin"
        /// Payload to helper: replace the text, the selection going to its end.
        public static let setString = "setString"
        /// Payload to helper: commit any composing text and let the field go.
        public static let end = "end"
        /// Helper to payload: the text or its composing state changed.
        public static let changed = "changed"
    }
}
