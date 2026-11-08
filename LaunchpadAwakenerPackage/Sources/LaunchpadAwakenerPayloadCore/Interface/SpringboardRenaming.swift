import Foundation

/// What renaming a folder stores once the text input helper's field has ended.
enum SpringboardRenaming {
    /// The name to store after the hosted field ended, when it differs from the one just committed: text
    /// an input method was still composing, which the helper committed on its way out. Nil when there is
    /// nothing to change, or when the helper never hosted the field — its answer is then not what was
    /// typed, which the springboard edited itself.
    static func lateTitle(endedString: String, committedTitle: String, previousTitle: String, wasHosted: Bool) -> String? {
        guard wasHosted else { return nil }
        let lateTitle = endedString.trimmingCharacters(in: .whitespaces)
        let titleNow = committedTitle.isEmpty ? previousTitle : committedTitle
        guard !lateTitle.isEmpty, lateTitle != titleNow else { return nil }
        return lateTitle
    }
}
