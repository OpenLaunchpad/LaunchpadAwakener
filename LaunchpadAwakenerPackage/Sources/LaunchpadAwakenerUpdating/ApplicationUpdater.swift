import AppKit
import Observation
import OSToolbox
import Sparkle

/// The app's updates: Sparkle's standard updater and its windows, checking the app's own feed once a day.
///
/// Both apps run in the background — the injected one in the menu bar, the standalone one hidden between
/// uses — so an update a scheduled check finds may first be a reminder rather than Sparkle's window; how,
/// is ``ScheduledUpdatePresentation``. A check the user starts always shows the window at once.
///
/// A build with no feed — a development build launched without `-UpdateFeedURL <url>` — or no key to check
/// signatures against never starts the updater, and ``isStarted`` stays false so that no update item or
/// setting shows.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "ApplicationUpdater")
@Observable
@MainActor
public final class ApplicationUpdater {
    /// How an update found by a scheduled check reaches the user.
    public enum ScheduledUpdatePresentation: Sendable {
        /// Sparkle shows its window; when it shows it behind other apps, the app adds a reminder too.
        case shownBySparkle
        /// The app only reminds, and Sparkle's window shows once the user asks for it.
        case remindedByApplication
    }

    public let scheduledUpdatePresentation: ScheduledUpdatePresentation

    /// Whether the updater runs. False in a build with no feed: nothing checks, and no update item shows.
    public private(set) var isStarted = false

    /// Whether a check can start now; false while one runs or its window is up.
    public private(set) var canCheckForUpdates = false

    /// Whether Sparkle checks once a day by itself. On unless the user turned it off.
    public var automaticallyChecksForUpdates: Bool {
        get { updaterController.updater.automaticallyChecksForUpdates }
        set { updaterController.updater.automaticallyChecksForUpdates = newValue }
    }

    /// The version and build of the running app, as the settings show them.
    public let currentVersionDescription: String

    /// The update the app reminds of: one a scheduled check found and Sparkle did not show in front.
    public var pendingUpdate: PendingUpdate? {
        reminder.pendingUpdate
    }

    fileprivate var reminder = UpdateReminder()

    /// Runs just before Sparkle's window shows at the user's request, to clear the way for it: the
    /// standalone app hides its springboard, which would cover the window, and unhides itself.
    @ObservationIgnored
    public var prepareToShowWindow: (@MainActor () -> Void)?

    @ObservationIgnored
    private let feedURL: URL?
    @ObservationIgnored
    private let delegate: UpdaterDelegate
    @ObservationIgnored
    private let updaterController: SPUStandardUpdaterController
    @ObservationIgnored
    private var canCheckForUpdatesObservation: NSKeyValueObservation?

    public init(
        scheduledUpdatePresentation: ScheduledUpdatePresentation,
        bundle: Bundle = .main,
        defaults: UserDefaults = .standard
    ) {
        self.scheduledUpdatePresentation = scheduledUpdatePresentation
        // Without the key that signs the updates Sparkle installs none of them, and complains at launch.
        let publicKey = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let feedURL = publicKey.isEmpty ? nil : UpdateFeedResolution.feedURL(of: bundle, defaults: defaults)
        self.feedURL = feedURL
        let shortVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        let buildVersion = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        currentVersionDescription = "Version \(shortVersion) (\(buildVersion))"
        let delegate = UpdaterDelegate(
            feedURL: feedURL,
            scheduledUpdatePresentation: scheduledUpdatePresentation,
            relaunchRecord: UpdateRelaunchRecord(defaults: defaults)
        )
        self.delegate = delegate
        // Sparkle keeps its delegates weakly: this object holds the one it is given.
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: delegate)
        delegate.applicationUpdater = self
    }

    /// Starts checking, when the build has a feed. Call once, at launch, before building the menus.
    public func start() {
        guard !isStarted else { return }
        guard let feedURL else {
            #log(.info, "No update feed or no update key in this build: the updater stays off")
            return
        }
        updaterController.startUpdater()
        isStarted = true
        let updater = updaterController.updater
        canCheckForUpdates = updater.canCheckForUpdates
        canCheckForUpdatesObservation = updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
            MainActor.assumeIsolated {
                self?.canCheckForUpdates = updater.canCheckForUpdates
            }
        }
        #log(.info, "Checking for updates at \(feedURL.absoluteString, privacy: .public), automatically: \(updater.automaticallyChecksForUpdates, privacy: .public)")
    }

    /// Shows Sparkle's window: checking now, or showing the update a scheduled check already found.
    public func checkForUpdates() {
        guard isStarted else { return }
        prepareToShowWindow?()
        // A menu bar app is not active when its menu is used: unless it activates, the window opens
        // behind the app in front.
        NSApp.activate()
        updaterController.updater.checkForUpdates()
    }

    /// The item every menu shares: "Check for Updates…", or "Install Update <version>…" while the app
    /// reminds of one. Either shows Sparkle's window. In a menu that validates its items the title follows
    /// the reminder each time the menu opens; a menu rebuilt on opening gets a fresh item instead.
    public func makeMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem(
            title: UpdateReminder.menuItemTitle(for: pendingUpdate),
            action: #selector(UpdaterDelegate.checkForUpdatesFromMenuItem(_:)),
            keyEquivalent: ""
        )
        menuItem.target = delegate
        return menuItem
    }
}

/// Sparkle's delegates for ``ApplicationUpdater``, and the target of its menu items. Sparkle calls the
/// delegate methods on the main thread.
@MainActor
private final class UpdaterDelegate: NSObject {
    let feedURL: URL?
    let scheduledUpdatePresentation: ApplicationUpdater.ScheduledUpdatePresentation
    let relaunchRecord: UpdateRelaunchRecord
    weak var applicationUpdater: ApplicationUpdater?
    /// What Sparkle proposed for the scheduled update it is about to show; it says so only when asking
    /// whether to show it, one call before the one that shows it.
    private var isScheduledUpdateInImmediateFocus = false

    init(feedURL: URL?, scheduledUpdatePresentation: ApplicationUpdater.ScheduledUpdatePresentation, relaunchRecord: UpdateRelaunchRecord) {
        self.feedURL = feedURL
        self.scheduledUpdatePresentation = scheduledUpdatePresentation
        self.relaunchRecord = relaunchRecord
    }

    @objc func checkForUpdatesFromMenuItem(_ sender: Any?) {
        applicationUpdater?.checkForUpdates()
    }
}

extension UpdaterDelegate: NSMenuItemValidation {
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if menuItem.action == #selector(checkForUpdatesFromMenuItem(_:)) {
            menuItem.title = UpdateReminder.menuItemTitle(for: applicationUpdater?.pendingUpdate)
        }
        return true
    }
}

extension UpdaterDelegate: SPUUpdaterDelegate {
    /// The feed the updater was started with: the Info.plist's, or in a development build the one given at
    /// launch, which Sparkle would not read by itself.
    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURL?.absoluteString
    }

    /// Sparkle is about to quit the app and open the updated copy: the next launch finishes the update.
    func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        relaunchRecord.noteRelaunch()
    }
}

extension UpdaterDelegate: @preconcurrency SPUStandardUserDriverDelegate {
    var supportsGentleScheduledUpdateReminders: Bool {
        true
    }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        isScheduledUpdateInImmediateFocus = immediateFocus
        return UpdateReminder.letsSparkleShow(scheduledUpdatePresentation, immediateFocus: immediateFocus)
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        applicationUpdater?.reminder.updateWillShow(
            displayVersion: update.displayVersionString,
            isUserInitiated: state.userInitiated,
            isShownBySparkle: handleShowingUpdate,
            isInImmediateFocus: isScheduledUpdateInImmediateFocus
        )
        isScheduledUpdateInImmediateFocus = false
    }

    func standardUserDriverDidReceiveUserAttention(forUpdate update: SUAppcastItem) {
        applicationUpdater?.reminder.userSawUpdate()
    }

    func standardUserDriverWillFinishUpdateSession() {
        applicationUpdater?.reminder.sessionEnded()
    }
}
