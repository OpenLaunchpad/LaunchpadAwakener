import AppKit
import LaunchpadAwakenerAppUI

// Not `@main` on the delegate: AppKit's synthesized `main()` only calls `NSApplicationMain`, which takes
// the delegate from the main nib, and this app has none. `NSApplication.delegate` is weak, so the delegate
// is kept alive here for as long as `NSApplicationMain` runs, which is the life of the process.
MainActor.assumeIsolated {
    let applicationDelegate = ApplicationDelegate()
    NSApplication.shared.delegate = applicationDelegate
    withExtendedLifetime(applicationDelegate) {
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
