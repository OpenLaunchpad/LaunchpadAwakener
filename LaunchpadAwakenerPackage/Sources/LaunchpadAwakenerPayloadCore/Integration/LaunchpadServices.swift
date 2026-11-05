import Foundation

/// What runs in the Dock besides the hooks: the layout library, started once the hooks are in.
enum LaunchpadServices {
    static let library = LaunchpadLibrary(
        configuration: .standard(itemsPerPage: SpringboardPreferences.itemsPerPage),
        layoutHandler: { layout in
            await SpringboardController.shared.updateLayout(layout)
        }
    )

    static func start() {
        Task {
            await library.start()
        }
    }
}
