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
        let delegate = UpdaterDelegate(feedURL: feedURL)
        self.delegate = delegate
        // Sparkle keeps its delegates weakly: this object holds the one it is given.
        updaterController = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: delegate, userDriverDelegate: delegate)
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
        // A menu bar app is not active when its menu is used: unless it activates, the window opens
        // behind the app in front.
        NSApp.activate()
        updaterController.updater.checkForUpdates()
    }
}

/// Sparkle's delegates for ``ApplicationUpdater``. Sparkle calls them on the main thread.
@MainActor
private final class UpdaterDelegate: NSObject {
    let feedURL: URL?

    init(feedURL: URL?) {
        self.feedURL = feedURL
    }
}

extension UpdaterDelegate: SPUUpdaterDelegate {
    /// The feed the updater was started with: the Info.plist's, or in a development build the one given at
    /// launch, which Sparkle would not read by itself.
    func feedURLString(for updater: SPUUpdater) -> String? {
        feedURL?.absoluteString
    }
}

extension UpdaterDelegate: SPUStandardUserDriverDelegate {}
