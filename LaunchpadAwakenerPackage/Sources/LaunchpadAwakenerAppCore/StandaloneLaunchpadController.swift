import AppKit
import OSToolbox

/// The standalone Launchpad as the control panel offers it while System Integrity Protection keeps this app
/// from injecting into the Dock: whether it is installed, installing it from the copy embedded in this app,
/// and opening it.
///
/// Read again on every refresh rather than remembered: the user can install, move or delete the app in
/// the Finder while this one runs.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "StandaloneLaunchpadController")
@Observable
@MainActor
public final class StandaloneLaunchpadController {
    /// Where the installed standalone app is; nil while it is not installed.
    public private(set) var installedApplicationURL: URL?
    public private(set) var isInstalling = false
    /// Most recent failure, cleared on the next success. For display.
    public private(set) var lastErrorDescription: String?

    @ObservationIgnored
    private let installer: StandaloneLaunchpadInstaller

    public init(installer: StandaloneLaunchpadInstaller = StandaloneLaunchpadInstaller()) {
        self.installer = installer
        refreshStatus()
    }

    public var isInstalled: Bool {
        installedApplicationURL != nil
    }

    /// Whether this build carries the standalone app to install.
    public var canInstall: Bool {
        installer.archiveURL != nil
    }

    public func refreshStatus() {
        let registeredApplicationURLs = NSWorkspace.shared.urlsForApplications(withBundleIdentifier: StandaloneLaunchpadInstaller.bundleIdentifier)
        installedApplicationURL = installer.installedApplicationURL(registeredApplicationURLs: registeredApplicationURLs)
    }

    /// Installs the standalone app into the Applications folder, then opens it.
    public func installAndOpen() async {
        guard !isInstalling else { return }
        isInstalling = true
        defer { isInstalling = false }
        do {
            let applicationURL = try await installer.install()
            installedApplicationURL = applicationURL
            lastErrorDescription = nil
            #log(.info, "Installed the standalone Launchpad at \(applicationURL.path, privacy: .public)")
            open(applicationURL)
        } catch {
            lastErrorDescription = "Could not install Launchpad: \(error.localizedDescription)"
            #log(.error, "Could not install the standalone Launchpad: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Opens the installed standalone app; it shows Launchpad at once.
    public func open() {
        refreshStatus()
        guard let installedApplicationURL else { return }
        open(installedApplicationURL)
    }

    private func open(_ applicationURL: URL) {
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: NSWorkspace.OpenConfiguration()) { [weak self] _, error in
            let errorDescription = error?.localizedDescription
            Task { @MainActor in
                self?.recordOpening(of: applicationURL, errorDescription: errorDescription)
            }
        }
    }

    private func recordOpening(of applicationURL: URL, errorDescription: String?) {
        guard let errorDescription else {
            lastErrorDescription = nil
            return
        }
        lastErrorDescription = "Could not open Launchpad: \(errorDescription)"
        #log(.error, "Could not open \(applicationURL.path, privacy: .public): \(errorDescription, privacy: .public)")
    }
}
