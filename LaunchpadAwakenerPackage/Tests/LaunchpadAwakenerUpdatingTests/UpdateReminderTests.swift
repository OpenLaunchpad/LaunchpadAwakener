@testable import LaunchpadAwakenerUpdating
import Testing

/// When a background app reminds of an update a scheduled check found: the injected app lets Sparkle show
/// its window and reminds only when Sparkle shows it behind other apps; the standalone app, hidden between
/// uses, always reminds and never lets Sparkle show it by itself.
@Suite("Reminders of an update")
struct UpdateReminderTests {
    @Test("an app whose updates Sparkle shows lets it show scheduled ones, in focus or not", arguments: [true, false])
    func shownBySparkleLetsSparkleShowScheduledUpdates(immediateFocus: Bool) {
        #expect(UpdateReminder.letsSparkleShow(.shownBySparkle, immediateFocus: immediateFocus))
    }

    @Test("an app that reminds by itself never lets Sparkle show a scheduled update", arguments: [true, false])
    func remindedByApplicationNeverLetsSparkleShowScheduledUpdates(immediateFocus: Bool) {
        #expect(!UpdateReminder.letsSparkleShow(.remindedByApplication, immediateFocus: immediateFocus))
    }

    @Test("an update Sparkle shows behind other apps leaves a reminder")
    func updateShownOutOfFocusLeavesAReminder() {
        var reminder = UpdateReminder()
        reminder.updateWillShow(displayVersion: "1.2", isUserInitiated: false, isShownBySparkle: true, isInImmediateFocus: false)
        #expect(reminder.pendingUpdate == PendingUpdate(displayVersion: "1.2"))
    }

    @Test("an update Sparkle shows in focus leaves no reminder")
    func updateShownInFocusLeavesNoReminder() {
        var reminder = UpdateReminder()
        reminder.updateWillShow(displayVersion: "1.2", isUserInitiated: false, isShownBySparkle: true, isInImmediateFocus: true)
        #expect(reminder.pendingUpdate == nil)
    }

    @Test("an update the app shows itself leaves a reminder, in focus or not", arguments: [true, false])
    func updateTheApplicationShowsLeavesAReminder(isInImmediateFocus: Bool) {
        var reminder = UpdateReminder()
        reminder.updateWillShow(displayVersion: "1.2", isUserInitiated: false, isShownBySparkle: false, isInImmediateFocus: isInImmediateFocus)
        #expect(reminder.pendingUpdate == PendingUpdate(displayVersion: "1.2"))
    }

    @Test("a check the user started leaves no reminder, and clears one")
    func userInitiatedCheckLeavesNoReminder() {
        var reminder = UpdateReminder()
        reminder.updateWillShow(displayVersion: "1.2", isUserInitiated: false, isShownBySparkle: false, isInImmediateFocus: false)
        reminder.updateWillShow(displayVersion: "1.2", isUserInitiated: true, isShownBySparkle: true, isInImmediateFocus: true)
        #expect(reminder.pendingUpdate == nil)
    }

    @Test("the reminder goes once the user has seen the update")
    func reminderClearsWhenTheUserSeesTheUpdate() {
        var reminder = UpdateReminder()
        reminder.updateWillShow(displayVersion: "1.2", isUserInitiated: false, isShownBySparkle: true, isInImmediateFocus: false)
        reminder.userSawUpdate()
        #expect(reminder.pendingUpdate == nil)
    }

    @Test("the reminder goes when the update session ends")
    func reminderClearsWhenTheSessionEnds() {
        var reminder = UpdateReminder()
        reminder.updateWillShow(displayVersion: "1.2", isUserInitiated: false, isShownBySparkle: false, isInImmediateFocus: false)
        reminder.sessionEnded()
        #expect(reminder.pendingUpdate == nil)
    }

    @Test("the menu item offers the update waiting, or a check")
    func menuItemOffersTheWaitingUpdate() {
        #expect(UpdateReminder.menuItemTitle(for: PendingUpdate(displayVersion: "1.2")) == "Install Update 1.2…")
        #expect(UpdateReminder.menuItemTitle(for: nil) == "Check for Updates…")
    }
}
