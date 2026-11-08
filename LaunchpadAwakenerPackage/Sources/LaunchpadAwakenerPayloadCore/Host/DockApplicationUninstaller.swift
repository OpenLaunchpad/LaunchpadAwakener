import Foundation
import ObjectiveC
import OSToolbox

/// Deletes applications with the Dock's own uninstaller, the one macOS 15's Launchpad used.
///
/// `DockBar.environment.applicationUninstaller` is a `DockCore.SystemApplicationUninstaller`. 27.2 still
/// has it, callable through the Objective-C runtime, though nothing in that Dock calls it any more. It
/// hands the bundle to `uninstalld`, which the Dock is entitled to use: the application is deleted for
/// good — not moved to the Trash — with its preferences and containers, and a running copy is asked to
/// quit, then killed. Each method's signature is checked on the object's own class before the call; if
/// one does not match, deleting is unavailable and no close box shows.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "DockApplicationUninstaller")
@MainActor
enum DockApplicationUninstaller {
    private static let applicationUninstallerSelector = NSSelectorFromString("applicationUninstaller")
    private static let uninstallabilitySelector = NSSelectorFromString("uninstallabilityOfFileAtURL:")
    private static let uninstallSelector = NSSelectorFromString("uninstallBundleAtURL:handler:")

    /// `DockBar.environment.applicationUninstaller` with both methods as 27.2 has them; nil otherwise.
    private static var uninstaller: NSObject? {
        guard
            let environment = DockEnvironment.environmentObject,
            let uninstaller = DockEnvironment.checkedObjectValue(of: environment, selector: applicationUninstallerSelector),
            DockEnvironment.hasMethod(uninstaller, selector: uninstallabilitySelector, typeEncoding: "i24@0:8@16"),
            DockEnvironment.hasMethod(uninstaller, selector: uninstallSelector, typeEncoding: "v32@0:8@16@?24")
        else { return nil }
        return uninstaller
    }

    /// Whether the Dock's uninstaller can be called at all.
    static var isAvailable: Bool {
        uninstaller != nil
    }

    /// Whether the uninstaller takes the application: one from the App Store, a web app, a Shortcuts
    /// droplet or a wrapped application (`uninstallabilityOfFileAtURL:` answering 1), which is when 15
    /// showed the close box.
    static func canUninstall(applicationAt bundleURL: URL) -> Bool {
        guard let uninstaller else { return false }
        typealias UninstallabilityFunction = @convention(c) (AnyObject, Selector, NSURL) -> Int32
        let implementation = unsafeBitCast(uninstaller.method(for: uninstallabilitySelector), to: UninstallabilityFunction.self)
        return implementation(uninstaller, uninstallabilitySelector, bundleURL as NSURL) == 1
    }

    /// Deletes the application; `completion` runs on the main actor with whether it went.
    static func uninstall(applicationAt bundleURL: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void) {
        guard let uninstaller else {
            completion(false)
            return
        }
        #log(.info, "Deleting \(bundleURL.path, privacy: .public)")
        typealias UninstallFunction = @convention(c) (AnyObject, Selector, NSURL, @escaping @convention(block) (ObjCBool) -> Void) -> Void
        let implementation = unsafeBitCast(uninstaller.method(for: uninstallSelector), to: UninstallFunction.self)
        implementation(uninstaller, uninstallSelector, bundleURL as NSURL) { hasUninstalled in
            // The answer comes on an XPC or a global queue.
            let hasSucceeded = hasUninstalled.boolValue
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    completion(hasSucceeded)
                }
            }
        }
    }
}
