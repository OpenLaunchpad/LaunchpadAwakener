import Foundation

extension LaunchpadStore {
    /// Lays `discoveredApplications` out the way macOS 15 set up a new user: `mainPage` — normally
    /// ``DefaultLaunchpadLayout/mainPage``, the listed applications in order and then the Other folder —
    /// followed by every other application by name. Pages and folder pages hold at most `itemsPerPage`
    /// items each.
    package func buildDefaultLayout(
        from discoveredApplications: [DiscoveredApplication],
        mainPage: [DefaultLaunchpadLayout.Entry],
        itemsPerPage: Int
    ) throws {
        var applicationsByBundleIdentifier: [String: DiscoveredApplication] = [:]
        for discoveredApplication in discoveredApplications where applicationsByBundleIdentifier[discoveredApplication.bundleIdentifier] == nil {
            applicationsByBundleIdentifier[discoveredApplication.bundleIdentifier] = discoveredApplication
        }

        try performTransaction {
            var currentPageIdentifier: LaunchpadItemIdentifier?
            var currentPageItemCount = 0
            func pageWithRoom() throws -> LaunchpadItemIdentifier {
                if let currentPageIdentifier, currentPageItemCount < itemsPerPage {
                    return currentPageIdentifier
                }
                let newPageIdentifier = try appendPage(to: rootIdentifier)
                currentPageIdentifier = newPageIdentifier
                currentPageItemCount = 0
                return newPageIdentifier
            }

            var placedBundleIdentifiers: Set<String> = []
            for entry in mainPage {
                switch entry {
                case .application(let bundleIdentifier):
                    guard let application = applicationsByBundleIdentifier[bundleIdentifier], placedBundleIdentifiers.insert(bundleIdentifier).inserted else { continue }
                    try appendApplication(application.record, to: pageWithRoom())
                    currentPageItemCount += 1
                case let .folder(title, applicationBundleIdentifiers):
                    let folderApplications = applicationBundleIdentifiers.compactMap { bundleIdentifier in
                        placedBundleIdentifiers.insert(bundleIdentifier).inserted ? applicationsByBundleIdentifier[bundleIdentifier] : nil
                    }
                    guard !folderApplications.isEmpty else { continue }
                    let folder = try appendFolder(titled: title, to: pageWithRoom())
                    currentPageItemCount += 1
                    var folderPageIdentifier = folder.firstPage
                    for (applicationIndex, application) in folderApplications.enumerated() {
                        if applicationIndex > 0, applicationIndex.isMultiple(of: itemsPerPage) {
                            folderPageIdentifier = try appendPage(to: folder.folder)
                        }
                        try appendApplication(application.record, to: folderPageIdentifier)
                    }
                }
            }

            let remainingApplications = applicationsByBundleIdentifier.values
                .filter { !placedBundleIdentifiers.contains($0.bundleIdentifier) }
                .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            for application in remainingApplications {
                try appendApplication(application.record, to: pageWithRoom())
                currentPageItemCount += 1
            }
            try setInformation("discovery", forKey: LaunchpadDatabaseSchema.InformationKey.layoutOrigin)
        }
    }
}
