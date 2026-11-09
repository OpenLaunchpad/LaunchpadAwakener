import AppKit

/// How this launch of the app came about.
public enum ApplicationLaunch {
    /// Whether the app was opened at login, as an item under Open at Login, rather than by the user.
    ///
    /// Only meaningful inside `applicationDidFinishLaunching(_:)`, while the open-application event is
    /// still the current Apple event; read later, the current event is whatever arrived next.
    @MainActor
    public static var wasLaunchedAtLogin: Bool {
        isLaunchAtLogin(openEvent: NSAppleEventManager.shared().currentAppleEvent)
    }

    /// The rule itself, apart from the event manager so that tests can hand it events.
    ///
    /// The open-application event of a launch at login carries `keyAELaunchedAsLogInItem` as its
    /// property data. One sent by the Finder, the Dock or `open` carries nothing there.
    static func isLaunchAtLogin(openEvent: NSAppleEventDescriptor?) -> Bool {
        guard let openEvent, openEvent.eventID == kAEOpenApplication else { return false }
        return openEvent.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
