import Foundation

/// The Dock preferences macOS 15's Launchpad read, for example
/// `defaults write com.apple.dock springboard-columns -int 8` followed by `killall Dock`.
///
/// Read from the host's ``SpringboardHost/preferences``: the `com.apple.dock` domain in the Dock and in the
/// standalone app alike. Rows and columns are clamped to 2…100 as 15 clamped them (`sub_100008170`).
package enum SpringboardPreferences {
    package static var rowCount: Int {
        clampedGridCount(forKey: "springboard-rows", defaultCount: 5)
    }

    package static var columnCount: Int {
        clampedGridCount(forKey: "springboard-columns", defaultCount: 7)
    }

    package static var itemsPerPage: Int {
        rowCount * columnCount
    }

    /// `springboard-zoom-style`: 0 widens only the side margins on wide screens, 1 only the top,
    /// 2 also the bottom.
    package static var zoomStyle: Int {
        SpringboardHostSystem.preferences.integer(forKey: "springboard-zoom-style")
    }

    /// `springboard-page-duration`, in seconds; 0.5 unless set.
    package static var pageAnimationDuration: CFTimeInterval {
        let duration = SpringboardHostSystem.preferences.double(forKey: "springboard-page-duration")
        return duration > 0 ? duration : 0.5
    }

    /// `springboard-reverse-scroll-gesture`: whether content moves with the fingers. On unless set.
    package static var reversesScrollGesture: Bool {
        SpringboardHostSystem.preferences.object(forKey: "springboard-reverse-scroll-gesture") as? Bool ?? true
    }

    /// `springboard-show-duration` and `springboard-hide-duration`, in seconds; 0.25 unless set.
    package static var showAnimationDuration: CFTimeInterval {
        positiveDuration(forKey: "springboard-show-duration") ?? 0.25
    }

    package static var hideAnimationDuration: CFTimeInterval {
        positiveDuration(forKey: "springboard-hide-duration") ?? 0.25
    }

    /// Accessibility's Reduce Motion: 15 then faded without scaling.
    package static var reducesMotion: Bool {
        CFPreferencesCopyAppValue("reduceMotion" as CFString, "com.apple.universalaccess" as CFString) as? Bool ?? false
    }

    /// Whether Spotlight has stopped answering the pinch itself. Only then does the Dock take it over —
    /// otherwise both would open together. `defaults write com.apple.spotlight trackpadAppBrowseEnabled -bool NO`
    /// turns Spotlight's off.
    package static var isSpotlightPinchDisabled: Bool {
        CFPreferencesCopyAppValue("trackpadAppBrowseEnabled" as CFString, "com.apple.spotlight" as CFString) as? Bool == false
    }

    private static func positiveDuration(forKey key: String) -> CFTimeInterval? {
        let duration = SpringboardHostSystem.preferences.double(forKey: key)
        return duration > 0 ? duration : nil
    }

    /// `springboard-background`: `glass` puts the Dock's own Liquid Glass behind the pages; anything else,
    /// or nothing, macOS 15's blurred wallpaper. Not one of macOS 15's keys; read each time the springboard
    /// opens.
    static var backgroundStyle: SpringboardBackground.Style {
        SpringboardHostSystem.preferences.string(forKey: "springboard-background").flatMap(SpringboardBackground.Style.init(rawValue:)) ?? .wallpaper
    }

    /// `springboard-glass-variant`: which of the Dock's glasses the glass background uses — 0 the Dock's
    /// own, 2 the same without foreground effects, 4 the Command-Tab switcher's. 0 unless set. Not one of
    /// macOS 15's keys; read each time the springboard opens.
    package static var glassVariant: Int {
        SpringboardHostSystem.preferences.integer(forKey: "springboard-glass-variant")
    }

    /// `springboard-edit-group-title`: whether clicking an open folder's title renames it. On unless set.
    package static var allowsRenamingFolders: Bool {
        SpringboardHostSystem.preferences.object(forKey: "springboard-edit-group-title") as? Bool ?? true
    }

    private static func clampedGridCount(forKey key: String, defaultCount: Int) -> Int {
        guard SpringboardHostSystem.preferences.object(forKey: key) != nil else { return defaultCount }
        return min(max(SpringboardHostSystem.preferences.integer(forKey: key), 2), 100)
    }
}
