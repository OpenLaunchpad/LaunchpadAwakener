/// An update waiting for the user, while the app reminds of it.
public struct PendingUpdate: Equatable, Sendable {
    /// The version as the user knows it, such as "1.2".
    public let displayVersion: String

    public init(displayVersion: String) {
        self.displayVersion = displayVersion
    }
}

/// Whether the app reminds of an update a scheduled check found, Sparkle's gentle reminders reduced to
/// values (Sparkle's own callback types cannot be made in a test).
///
/// Sparkle shows an update of a background app behind the other apps unless it judges the moment one of
/// immediate focus (just launched, or back from idle). The injected app has no Dock icon to bring that
/// window forward, and the standalone one is hidden between uses and covers everything while it shows; so
/// the injected app adds a reminder to its menu bar menu whenever Sparkle shows the update out of focus,
/// and the standalone app always reminds instead of letting Sparkle show it.
public struct UpdateReminder: Equatable, Sendable {
    /// The update the app reminds of, or nil.
    public private(set) var pendingUpdate: PendingUpdate?

    public init() {}

    /// Whether Sparkle shows an update a scheduled check found itself, rather than the app reminding of it.
    public static func letsSparkleShow(_ presentation: ApplicationUpdater.ScheduledUpdatePresentation, immediateFocus: Bool) -> Bool {
        switch presentation {
        case .shownBySparkle: true
        case .remindedByApplication: false
        }
    }

    /// Sparkle is about to show an update, itself or through the app.
    ///
    /// - Parameters:
    ///   - isUserInitiated: The user started the check, so they are looking at its window already.
    ///   - isShownBySparkle: Sparkle shows its window now, rather than leaving the update to the app.
    ///   - isInImmediateFocus: Sparkle shows it in front, rather than behind the other apps.
    public mutating func updateWillShow(displayVersion: String, isUserInitiated: Bool, isShownBySparkle: Bool, isInImmediateFocus: Bool) {
        if isUserInitiated || (isShownBySparkle && isInImmediateFocus) {
            pendingUpdate = nil
        } else {
            pendingUpdate = PendingUpdate(displayVersion: displayVersion)
        }
    }

    /// The user brought the update's window up.
    public mutating func userSawUpdate() {
        pendingUpdate = nil
    }

    /// The update was installed, skipped or put off until the next check.
    public mutating func sessionEnded() {
        pendingUpdate = nil
    }

    /// The title of the menu item every update entry shares.
    public static func menuItemTitle(for pendingUpdate: PendingUpdate?) -> String {
        if let pendingUpdate {
            "Install Update \(pendingUpdate.displayVersion)…"
        } else {
            "Check for Updates…"
        }
    }
}
