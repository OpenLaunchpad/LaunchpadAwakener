import Foundation

/// Names shared by the payload and the text input helper, the LaunchAgent that hosts the springboard's
/// text fields so that input methods work in them, as macOS 15's `com.apple.dock.ecti` service did.
///
/// The matching build setting is `TEXT_INPUT_SERVICE_NAME`; the two must agree, as the daemon's
/// `INJECTION_SERVICE_NAME` and ``InjectionServiceIdentity/machServiceName`` must. The messages are in
/// `TextInputMessages.swift`.
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

    /// The helper's executable, relative to the app bundle's root: the LaunchAgent's `BundleProgram`, which
    /// the build script that writes its property list spells the same way. The helper's bundle identifier
    /// is ``machServiceName``, from the same build setting.
    public static let helperBundleProgram = "Contents/Library/LoginItems/LaunchpadAwakenerTextInput.app/Contents/MacOS/LaunchpadAwakenerTextInput"

    /// Signing identifier of the only peer the helper accepts: the Dock, which also has to be platform code,
    /// part of the system. Checked by libxpc on every message, so neither another process nor a recycled
    /// process identifier gets the typed text.
    public static let dockSigningIdentifier = "com.apple.dock"
}
