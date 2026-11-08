import Foundation

/// What runs in the Dock besides the hooks: the layout library, started once the hooks are in.
package enum LaunchpadServices {
    package static let library = LaunchpadLibrary(
        configuration: SpringboardHostSystem.host.libraryConfiguration,
        layoutHandler: { layout in
            await SpringboardController.shared.updateLayout(layout)
        }
    )

    package static func start() {
        Task {
            await library.start()
        }
    }
}
