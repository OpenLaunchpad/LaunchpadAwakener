import Foundation

/// Names and versions shared by all four binaries in this project: the app, the privileged
/// daemon, the injected payload, and anything that talks to them.
///
/// Everything here is a single source of truth on the Swift side. The matching
/// `INJECTION_SERVICE_NAME` build settings live in `LaunchpadAwakener.xcodeproj/project.pbxproj`;
/// the two definitions must agree. If you rename the service, change it in both places. The
/// daemon's executable is called `LaunchpadAwakenerDaemon` in every configuration and does not
/// follow the service name.
public enum InjectionServiceIdentity {
    /// Mach service name the daemon publishes and the app connects to.
    ///
    /// Debug and release use distinct names so a development build and an installed release build
    /// can each own their own daemon without fighting over one Mach service registration.
    public static let machServiceName: String = {
        #if DEBUG
        "com.MxIris.LaunchpadAwakener.service.debug"
        #else
        "com.MxIris.LaunchpadAwakener.service"
        #endif
    }()

    /// File name of the launchd property list inside `Contents/Library/LaunchDaemons/`.
    ///
    /// `SMAppService.daemon(plistName:)` takes exactly this string. The build generates the file
    /// under this name, so the two stay in step automatically.
    public static var daemonPropertyListName: String { "\(machServiceName).plist" }

    /// File name of the daemon's executable inside `Contents/Library/LaunchServices/`.
    ///
    /// The daemon target's product name, the same in every configuration: Xcode does not evaluate a
    /// file reference's path per configuration, so an executable named after the service would leave
    /// the Embed Daemon copy looking for the Debug name in a Release build. The payload compares its
    /// host's executable name against this to tell that it was loaded inside the daemon.
    public static let daemonExecutableName = "LaunchpadAwakenerDaemon"

    /// Version string the daemon reports over XPC.
    ///
    /// The app compares this against the running daemon and reinstalls on mismatch, which is what
    /// makes "I rebuilt the daemon but the old one is still resident" stop being a debugging
    /// session. Bump it whenever the daemon's request surface or bundled executable path changes.
    public static let daemonVersion = "1.1.1"

    /// Where the app asks the daemon to place the payload before injecting it.
    ///
    /// A root-owned directory outside the app bundle is deliberate: the payload has to stay
    /// readable after the app quits, and it must not sit anywhere an unprivileged process could
    /// swap it out between installation and injection.
    public static let payloadInstallationDirectory = URL(fileURLWithPath: "/Library/Application Support/LaunchpadAwakener", isDirectory: true)

    /// Bundle name of the payload framework as it ships inside the app's `Resources`.
    public static let payloadFrameworkName = "LaunchpadAwakenerPayload"

    /// Entry symbol the remap injection path calls inside the payload.
    ///
    /// Must match the symbol exported by `LaunchpadAwakenerPayload/main.m`. Only the remap path uses it;
    /// the `dlopen` path runs the payload's constructor instead.
    public static let payloadRemapEntrySymbol = "LaunchpadAwakener_payload_remap_entry"
}
