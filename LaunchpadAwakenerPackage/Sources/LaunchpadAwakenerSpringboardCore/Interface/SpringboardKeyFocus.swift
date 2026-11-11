/// What macOS 15 did when the keyboard left Launchpad, and the window server's notifications that say so.
///
/// The window server tells the process holding the key focus — taken with `CPSStealKeyFocusOnConnection`, as
/// the springboard takes it — when that focus changes: CGEvent type 21, with a code in field 64. 15.5's
/// `ECModalEventController` turned the codes 0x1000, 0xF102 and 0x4000 into `-[Springboard lostKeyFocus:]`
/// (`0x10009262C`), and that hid Launchpad unless one of three held:
///
/// - the code was 0x4000, whatever else was going on;
/// - the confirmation for deleting an application was up (`+[ECAlertPanel activeAlertPanel]`);
/// - text was being edited (`-[ECSBSpringboard activeTextInputLayer]`, `0x1000F286C`).
///
/// Apple names none of the codes. The 27.2 Dock's own use of them
/// (`-[DockBarNotificationEventHandler handleNotificationEvent:type:]`, `0x1000852A0`) suggests 0x1000 is the
/// focus lost and 0x4000 the focus handed to another process, the one in field 73: the Dock lets 0x4000 pass when
/// that process shows the Dock's own menu. Which of the two a click on another display's application sends has not
/// been seen; the controller logs every code, with that process, so that it can be.
package enum SpringboardKeyFocus {
    package static let notificationEventType: UInt32 = 21
    package static let codeField: UInt32 = 64
    package static let otherProcessField: UInt32 = 73

    package static let lostCode: Int64 = 0x1000
    package static let handedToAnotherProcessCode: Int64 = 0x4000
    /// Taken by 15 as the focus lost; what sends it is not known.
    package static let unexplainedLossCode: Int64 = 0xF102

    /// Whether a key focus notification hides the springboard, as it hid 15's Launchpad.
    /// - Parameters:
    ///   - isEditingText: The search field has the focus or text in it, or a folder's name is being edited.
    ///   - isAskingToDelete: The confirmation for deleting an application is up, whoever shows it.
    package static func hidesSpringboard(notificationCode: Int64, isEditingText: Bool, isAskingToDelete: Bool) -> Bool {
        guard notificationCode == lostCode || notificationCode == unexplainedLossCode else { return false }
        return !isEditingText && !isAskingToDelete
    }
}
