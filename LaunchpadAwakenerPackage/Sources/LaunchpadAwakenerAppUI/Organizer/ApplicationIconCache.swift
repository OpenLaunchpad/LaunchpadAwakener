import AppKit

/// Icons of the listed applications, read once per bundle path.
@MainActor
final class ApplicationIconCache {
    static let shared = ApplicationIconCache()

    private let icons = NSCache<NSString, NSImage>()

    func icon(for bundleURL: URL?) -> NSImage {
        guard let bundleURL else {
            return NSWorkspace.shared.icon(for: .applicationBundle)
        }
        if let icon = icons.object(forKey: bundleURL.path as NSString) {
            return icon
        }
        let icon = NSWorkspace.shared.icon(forFile: bundleURL.path)
        icons.setObject(icon, forKey: bundleURL.path as NSString)
        return icon
    }
}
