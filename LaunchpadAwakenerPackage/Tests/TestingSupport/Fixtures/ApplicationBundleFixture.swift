import Foundation

/// Writes a minimal application bundle — a directory and an Info.plist — for discovery to find.
package struct ApplicationBundleFixture {
    package var name: String
    package var bundleIdentifier: String
    package var isBackgroundOnly = false

    package init(name: String, bundleIdentifier: String, isBackgroundOnly: Bool = false) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.isBackgroundOnly = isBackgroundOnly
    }

    /// Writes `<name>.app` inside `directoryURL`, creating the directory as needed. Returns the bundle URL.
    @discardableResult
    package func write(in directoryURL: URL) throws -> URL {
        let bundleURL = directoryURL.appendingPathComponent("\(name).app", isDirectory: true)
        let contentsURL = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        var informationDictionary: [String: Any] = [
            "CFBundleIdentifier": bundleIdentifier,
            "CFBundleName": name,
            "CFBundlePackageType": "APPL",
        ]
        if isBackgroundOnly {
            informationDictionary["LSBackgroundOnly"] = true
        }
        let informationData = try PropertyListSerialization.data(fromPropertyList: informationDictionary, format: .xml, options: 0)
        try informationData.write(to: contentsURL.appendingPathComponent("Info.plist"))
        return bundleURL
    }
}
