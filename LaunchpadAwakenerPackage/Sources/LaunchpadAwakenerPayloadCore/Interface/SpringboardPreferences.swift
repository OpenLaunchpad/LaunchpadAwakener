import Foundation

/// The Dock preferences macOS 15's Launchpad read, for example
/// `defaults write com.apple.dock springboard-columns -int 8` followed by `killall Dock`.
///
/// Inside the Dock, `UserDefaults.standard` is the `com.apple.dock` domain. Rows and columns are clamped
/// to 2…100 as 15 clamped them (`sub_100008170`).
enum SpringboardPreferences {
    static var rowCount: Int {
        clampedGridCount(forKey: "springboard-rows", defaultCount: 5)
    }

    static var columnCount: Int {
        clampedGridCount(forKey: "springboard-columns", defaultCount: 7)
    }

    static var itemsPerPage: Int {
        rowCount * columnCount
    }

    /// `springboard-zoom-style`: 0 widens only the side margins on wide screens, 1 only the top,
    /// 2 also the bottom.
    static var zoomStyle: Int {
        UserDefaults.standard.integer(forKey: "springboard-zoom-style")
    }

    /// `springboard-page-duration`, in seconds; 0.5 unless set.
    static var pageAnimationDuration: CFTimeInterval {
        let duration = UserDefaults.standard.double(forKey: "springboard-page-duration")
        return duration > 0 ? duration : 0.5
    }

    /// `springboard-reverse-scroll-gesture`: whether content moves with the fingers. On unless set.
    static var reversesScrollGesture: Bool {
        UserDefaults.standard.object(forKey: "springboard-reverse-scroll-gesture") as? Bool ?? true
    }

    /// `springboard-show-duration` and `springboard-hide-duration`, in seconds; 0.25 unless set.
    static var showAnimationDuration: CFTimeInterval {
        positiveDuration(forKey: "springboard-show-duration") ?? 0.25
    }

    static var hideAnimationDuration: CFTimeInterval {
        positiveDuration(forKey: "springboard-hide-duration") ?? 0.25
    }

    /// Accessibility's Reduce Motion: 15 then faded without scaling.
    static var reducesMotion: Bool {
        CFPreferencesCopyAppValue("reduceMotion" as CFString, "com.apple.universalaccess" as CFString) as? Bool ?? false
    }

    /// Whether Spotlight has stopped answering the pinch itself. Only then does the Dock take it over —
    /// otherwise both would open together. `defaults write com.apple.spotlight trackpadAppBrowseEnabled -bool NO`
    /// turns Spotlight's off.
    static var isSpotlightPinchDisabled: Bool {
        CFPreferencesCopyAppValue("trackpadAppBrowseEnabled" as CFString, "com.apple.spotlight" as CFString) as? Bool == false
    }

    private static func positiveDuration(forKey key: String) -> CFTimeInterval? {
        let duration = UserDefaults.standard.double(forKey: key)
        return duration > 0 ? duration : nil
    }

    /// `springboard-glass-variant`: which of the Dock's glasses the background uses — 0 the Dock's own,
    /// 2 the same without foreground effects, 4 the Command-Tab switcher's. 0 unless set. Not one of
    /// macOS 15's keys; read each time the springboard opens.
    static var glassVariant: Int {
        UserDefaults.standard.integer(forKey: "springboard-glass-variant")
    }

    /// `springboard-edit-group-title`: whether clicking an open folder's title renames it. On unless set.
    static var allowsRenamingFolders: Bool {
        UserDefaults.standard.object(forKey: "springboard-edit-group-title") as? Bool ?? true
    }

    private static func clampedGridCount(forKey key: String, defaultCount: Int) -> Int {
        guard UserDefaults.standard.object(forKey: key) != nil else { return defaultCount }
        return min(max(UserDefaults.standard.integer(forKey: key), 2), 100)
    }
}
