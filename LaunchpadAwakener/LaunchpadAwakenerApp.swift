import SwiftUI
import AppKit
import LaunchpadAwakenerAppCore

@main
struct LaunchpadAwakenerApp: App {
    /// Everything with a lifetime is owned by the delegate, not by this struct.
    ///
    /// Launch work hung off the window's `.task` stops being a launch hook the moment the window can
    /// legitimately not appear — exactly what launching at login does. `applicationDidFinishLaunching`
    /// fires whether or not anything is on screen.
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var applicationDelegate

    /// Kept free between the window's content and the edges of the screen's visible area: the title
    /// bar, which the placement's size does not include, and a margin.
    private static let screenEdgeAllowance: CGFloat = 72

    var body: some Scene {
        Window("LaunchpadAwakener", id: WindowIdentifier.main) {
            MainView()
                .environment(applicationDelegate.daemonController)
                .environment(applicationDelegate.injectionCoordinator)
                .environment(applicationDelegate.launchAtLoginController)
                .environment(applicationDelegate.launchProgress)
                .environment(applicationDelegate.textInputAgentController)
                .environment(applicationDelegate.killSwitchController)
                .onAppear { applicationDelegate.activationPolicyController.windowDidAppear() }
                .onDisappear { applicationDelegate.activationPolicyController.windowDidDisappear() }
        }
        .windowResizability(.contentSize)
        // Opens as tall as the content and never taller than the screen's visible area, which leaves
        // out the menu bar and the Dock; a window sized to its content alone reached down behind the
        // Dock on the test MacBook. Past that height the form scrolls.
        .defaultWindowPlacement { content, context in
            let visibleRect = context.defaultDisplay.visibleRect
            let idealSize = content.sizeThatFits(.unspecified)
            return WindowPlacement(size: CGSize(
                width: idealSize.width,
                height: min(idealSize.height, visibleRect.height - Self.screenEdgeAllowance)
            ))
        }
        // Suppressed only while launching at login is on. With it off this launch cannot have come
        // from launchd, so the window appears — which is why nothing in this app has to detect where
        // a launch came from.
        .defaultLaunchBehavior(applicationDelegate.launchAtLoginController.isEnabled ? .suppressed : .presented)
        // `.suppressed` only applies "in the absence of any previously restored scenes". Without this,
        // quitting with the window open would have it restored straight past the suppression.
        .restorationBehavior(.disabled)

        MenuBarExtra {
            MenuBarContent()
                .environment(applicationDelegate.daemonController)
                .environment(applicationDelegate.injectionCoordinator)
                .environment(applicationDelegate.launchProgress)
                .environment(applicationDelegate.killSwitchController)
        } label: {
            MenuBarLabel(reopenRequest: applicationDelegate.reopenRequest)
        }
    }
}

enum WindowIdentifier {
    static let main = "main"
}

/// The menu bar icon, and the one view guaranteed to be alive while no window is open.
///
/// `openWindow` is a SwiftUI environment value, so something has to be in the view tree to read it.
/// Once the window closes this label is all that is left, which is why the reopen bridge lives on
/// the menu bar icon rather than next to the window it opens.
private struct MenuBarLabel: View {
    let reopenRequest: ApplicationReopenRequest

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Label("LaunchpadAwakener", systemImage: "square.grid.3x3.fill")
            .onChange(of: reopenRequest.reopenCount) {
                // An accessory app is not in the activation order, so opening a window without this
                // puts it behind whatever the user was looking at.
                ApplicationActivationPolicyController.activateForWindowPresentation()
                openWindow(id: WindowIdentifier.main)
            }
    }
}

/// Bumped each time the user launches the app while it is already running.
///
/// A counter rather than a boolean: two reopens in a row are two separate requests, and a boolean
/// that is already true would swallow the second one.
@MainActor
@Observable
final class ApplicationReopenRequest {
    private(set) var reopenCount = 0

    func record() {
        reopenCount += 1
    }
}

/// Owns the app's controllers and its launch sequence.
@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    let daemonController: PrivilegedDaemonController
    let injectionCoordinator: PayloadInjectionCoordinator
    let activationPolicyController = ApplicationActivationPolicyController()
    let launchAtLoginController = LaunchAtLoginController()
    let textInputAgentController = TextInputAgentController()
    let killSwitchController = KillSwitchController()
    let reopenRequest = ApplicationReopenRequest()
    let launchProgress = ApplicationLaunchProgress()

    override init() {
        let daemonController = PrivilegedDaemonController()
        self.daemonController = daemonController
        self.injectionCoordinator = PayloadInjectionCoordinator(
            daemonController: daemonController,
            // The Dock's executable path is fixed, so match on the full path rather than the name —
            // an unrelated process called "Dock" would otherwise be injected too.
            targetMatchingRule: .executablePath("/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"),
            injectionMethod: .dynamicLibraryLoad
        )
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A Dock injected once and not after the next login is a tool that silently stops working,
        // so the first time the tool works, launching at login is turned on — once, and only if the
        // user has not decided for themselves.
        injectionCoordinator.onInjectionSucceeded = { [launchAtLoginController] in
            launchAtLoginController.applyDefaultIfNeeded()
        }

        // Before anything that can fail. The monitor needs no daemon and no privileges — it reads the
        // process table — and it is what retries injection for as long as the app runs. Starting it
        // only once the daemon had been confirmed usable would make the one mechanism that can
        // recover from a bad launch the one thing a bad launch never reaches.
        injectionCoordinator.activateAutomaticInjectionIfEnabled()

        // Needs no daemon either: launchd only starts the helper when a payload connects to it.
        textInputAgentController.registerIfNeeded()

        Task { await runLaunchSequence() }
    }

    /// Reopens the window when the app is launched again while already running.
    ///
    /// With no Dock icon and no open window, opening the app from Finder produces a reopen rather
    /// than a launch, and SwiftUI has nothing to bring forward. Without this the menu bar item would
    /// be the only way back in — the state launching at login leaves the app in after every boot.
    func applicationShouldHandleReopen(_ application: NSApplication, hasVisibleWindows: Bool) -> Bool {
        guard !hasVisibleWindows else { return true }
        reopenRequest.record()
        return true
    }

    /// Runs the launch sequence again when it stopped, each time the app comes to the front.
    ///
    /// A launch stops when the daemon is not usable — most often because it still waits for approval
    /// in System Settings. Coming back from there activates the app, and the sequence then gets as
    /// far as it now can. Without this the banner kept the old reason ("Awaiting approval") after the
    /// approval, and with automatic injection off nothing reconnected to a Dock that already held the
    /// payload.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard case .stopped = launchProgress.phase else { return }
        // Entered here rather than inside the task, so that a second activation in the meantime sees
        // a sequence in progress and does not start another.
        launchProgress.enter(.preparingDaemon)
        Task { await runLaunchSequence() }
    }

    /// Gets the app to a working state, recording how far it got.
    ///
    /// Every step that cannot proceed is recorded rather than returned from silently: a launch that
    /// could not reach the daemon must not produce a window that looks exactly like a healthy one.
    private func runLaunchSequence() async {
        launchProgress.enter(.preparingDaemon)

        let availability = await daemonController.ensureDaemonUsable()
        guard availability.isUsable else {
            // Not the end of the road: the process monitor is already running, and every injection
            // it attempts makes the daemon usable first. This says where things stand right now.
            launchProgress.enter(.stopped(reason: availability.summary))
            return
        }

        // Pick up payloads still running from an earlier session before deciding anything else.
        // Skipping this makes a relaunched app report "not injected" while the payload is right
        // there, and the obvious response — injecting again — does nothing, because a mapped image
        // cannot be loaded twice.
        launchProgress.enter(.reconnectingToPayloads)
        await injectionCoordinator.reconnectToResidentPayloads()

        if injectionCoordinator.isAutomaticInjectionEnabled {
            launchProgress.enter(.injecting)
            await injectionCoordinator.injectIntoRunningTargets()
        }

        launchProgress.enter(.ready)
    }
}
