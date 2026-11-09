import CoreServices
import Foundation

/// An application bundle found on disk.
package struct DiscoveredApplication: Sendable, Equatable {
    package let url: URL
    package let bundleIdentifier: String
    /// The localized name the Finder shows, without `.app`.
    package let title: String

    package init(url: URL, bundleIdentifier: String, title: String) {
        self.url = url
        self.bundleIdentifier = bundleIdentifier
        self.title = title
    }

    package var record: LaunchpadApplicationRecord {
        LaunchpadApplicationRecord(
            title: title,
            bundleIdentifier: bundleIdentifier,
            modificationDate: Date().timeIntervalSinceReferenceDate,
            bookmarkData: try? url.bookmarkData()
        )
    }
}

/// Where an application's bookmark leads.
package enum BookmarkedBundle: Sendable, Equatable {
    /// To a bundle with the application's identifier.
    case found(URL)
    /// To a bundle that now has another identifier: the application there was replaced in place, as when
    /// a Setapp build or a fork takes over the same path.
    case replaced(URL)
    /// Nowhere: there is no bookmark, or the bundle it led to is gone.
    case missing
}

/// Finds the applications Launchpad shows; the scanning half of macOS 15's `LPAppSource`.
package enum ApplicationDiscovery {
    /// How deep below a search directory folders are searched, as in `/Applications/Vendor/Suite/Tool.app`.
    package static let maximumFolderDepth = 4

    /// The places macOS 15 listed in its `app_sources` table, in the order duplicates are resolved:
    /// `/Applications`, the read-only system applications, the cryptex that carries Safari, and
    /// `~/Applications`.
    package static var standardSearchDirectories: [URL] {
        [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Cryptexes/App/System/Applications", isDirectory: true),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
        ]
    }

    /// Every application in `searchDirectories` that `exclusionList` lets through. An application
    /// reachable more than once — through a symbolic link, say — is listed once, under the first path.
    package static func discoverApplications(
        in searchDirectories: [URL],
        exclusionList: ApplicationExclusionList
    ) -> [DiscoveredApplication] {
        var discoveredApplications: [DiscoveredApplication] = []
        var seenResolvedPaths: Set<String> = []
        for searchDirectory in searchDirectories {
            for applicationURL in applicationBundleURLs(in: searchDirectory) {
                let resolvedPath = applicationURL.resolvingSymlinksInPath().standardizedFileURL.path
                guard
                    seenResolvedPaths.insert(resolvedPath).inserted,
                    let discoveredApplication = describeApplication(at: applicationURL),
                    !exclusionList.excludes(bundleIdentifier: discoveredApplication.bundleIdentifier, name: discoveredApplication.title)
                else { continue }
                discoveredApplications.append(discoveredApplication)
            }
        }
        return discoveredApplications
    }

    /// `.app` bundles in `directory` and its folders, never looking inside a bundle.
    private static func applicationBundleURLs(in directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var applicationURLs: [URL] = []
        for case let itemURL as URL in enumerator {
            if itemURL.pathExtension == "app" {
                applicationURLs.append(itemURL)
                // A symbolic link to a bundle is not a package to the enumerator; never descend.
                enumerator.skipDescendants()
            } else if enumerator.level >= maximumFolderDepth {
                enumerator.skipDescendants()
            }
        }
        return applicationURLs
    }

    /// Reads the bundle at `applicationURL`; nil for anything Launchpad would not show.
    private static func describeApplication(at applicationURL: URL) -> DiscoveredApplication? {
        guard
            let informationDictionary = informationDictionary(ofBundleAt: applicationURL),
            let bundleIdentifier = informationDictionary[kCFBundleIdentifierKey as String] as? String
        else { return nil }
        if isTrue(informationDictionary["LSBackgroundOnly"]) {
            return nil
        }
        var title = FileManager.default.displayName(atPath: applicationURL.path)
        if title.hasSuffix(".app") {
            title.removeLast(".app".count)
        }
        return DiscoveredApplication(url: applicationURL, bundleIdentifier: bundleIdentifier, title: title)
    }

    private static func isTrue(_ informationValue: Any?) -> Bool {
        switch informationValue {
        case let boolean as Bool: boolean
        case let number as NSNumber: number.boolValue
        case let string as String: string == "1" || string.caseInsensitiveCompare("YES") == .orderedSame || string.caseInsensitiveCompare("true") == .orderedSame
        default: false
        }
    }

    /// Where `application`'s bookmark leads now, and whether the bundle there is still that application.
    package static func bookmarkedBundle(of application: LaunchpadApplication) -> BookmarkedBundle {
        guard let bookmarkData = application.bookmarkData else { return .missing }
        var isStale = false
        guard
            let resolvedURL = try? URL(
                resolvingBookmarkData: bookmarkData,
                options: [.withoutUI, .withoutMounting],
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ),
            FileManager.default.fileExists(atPath: resolvedURL.path)
        else { return .missing }
        return bundleIdentifier(ofBundleAt: resolvedURL) == application.bundleIdentifier ? .found(resolvedURL) : .replaced(resolvedURL)
    }

    /// Every bundle LaunchServices knows with `bundleIdentifier` that is still there and still has it,
    /// wherever it is.
    package static func installedBundleURLs(forBundleIdentifier bundleIdentifier: String) -> [URL] {
        guard
            let applicationURLs = LSCopyApplicationURLsForBundleIdentifier(bundleIdentifier as CFString, nil)?
                .takeRetainedValue() as? [URL]
        else { return [] }
        return applicationURLs.filter { applicationURL in
            FileManager.default.fileExists(atPath: applicationURL.path) && self.bundleIdentifier(ofBundleAt: applicationURL) == bundleIdentifier
        }
    }

    /// The identifier of the bundle at `bundleURL`, read afresh.
    package static func bundleIdentifier(ofBundleAt bundleURL: URL) -> String? {
        informationDictionary(ofBundleAt: bundleURL)?[kCFBundleIdentifierKey as String] as? String
    }

    /// The bundle's Info.plist, read from disk each time. `Bundle(url:)` keeps the first one it read for a
    /// path for the life of the process, and the Dock lives for days: a bundle replaced in place — a new
    /// build with another identifier — would go on reading as the old one.
    ///
    /// iOS applications installed on a Mac are wrapped: the outer bundle has no Info.plist, the real one
    /// sits behind the `WrappedBundle` link.
    private static func informationDictionary(ofBundleAt bundleURL: URL) -> [String: Any]? {
        for candidateURL in [bundleURL, bundleURL.appendingPathComponent("WrappedBundle", isDirectory: true)] {
            if
                let informationDictionary = CFBundleCopyInfoDictionaryForURL(candidateURL as CFURL) as? [String: Any],
                informationDictionary[kCFBundleIdentifierKey as String] is String
            {
                return informationDictionary
            }
        }
        return nil
    }
}
