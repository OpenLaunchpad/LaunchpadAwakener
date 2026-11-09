import AppKit
import LaunchpadAwakenerStandaloneCore

// The standalone Launchpad: macOS 15's Launchpad in a window of its own, over the whole main display,
// without injecting into the Dock. Everything but this shell is in `LaunchpadAwakenerStandaloneCore`.
//
// Not `@main` on the delegate: AppKit's synthesized `main()` only calls `NSApplicationMain`, which takes
// the delegate from the main nib, and this app has none. `NSApplication.delegate` is weak, so the delegate
// is kept alive here for as long as `NSApplicationMain` runs, which is the life of the process.
MainActor.assumeIsolated {
    let applicationDelegate = StandaloneApplicationDelegate()
    NSApplication.shared.delegate = applicationDelegate
    withExtendedLifetime(applicationDelegate) {
        _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
    }
}
