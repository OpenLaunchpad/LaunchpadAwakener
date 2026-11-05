import CoreServices
import Foundation
import OSToolbox

/// Opens applications through LaunchServices on the springboard's behalf.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "ApplicationLauncher")
enum ApplicationLauncher {
    static func launchApplication(withBundleIdentifier bundleIdentifier: String) {
        guard
            let applicationURLs = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?
                .takeRetainedValue() as? [URL],
            let applicationURL = applicationURLs.first
        else {
            #log(.error, "No application found for \(bundleIdentifier, privacy: .public)")
            return
        }
        launchApplication(at: applicationURL)
    }

    static func launchApplication(at applicationURL: URL) {
        let launchStatus = LSOpenCFURLRef(applicationURL as CFURL, nil)
        #log(.info, "Launched \(applicationURL.path, privacy: .public): status \(launchStatus, privacy: .public)")
    }
}
