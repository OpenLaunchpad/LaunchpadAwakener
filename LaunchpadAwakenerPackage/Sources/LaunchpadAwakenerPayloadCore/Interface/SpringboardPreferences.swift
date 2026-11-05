import Foundation

/// The Dock preferences macOS 15's Launchpad read, for example
/// `defaults write com.apple.dock springboard-columns -int 8` followed by `killall Dock`.
///
/// Inside the Dock, `UserDefaults.standard` is the `com.apple.dock` domain.
enum SpringboardPreferences {
    static var rowCount: Int {
        positiveInteger(forKey: "springboard-rows") ?? 5
    }

    static var columnCount: Int {
        positiveInteger(forKey: "springboard-columns") ?? 7
    }

    static var itemsPerPage: Int {
        rowCount * columnCount
    }

    private static func positiveInteger(forKey key: String) -> Int? {
        let value = UserDefaults.standard.integer(forKey: key)
        return value > 0 ? value : nil
    }
}
