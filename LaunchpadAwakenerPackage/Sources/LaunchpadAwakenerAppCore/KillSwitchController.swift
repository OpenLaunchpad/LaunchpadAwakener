import Foundation
import LaunchpadAwakenerShared
import OSToolbox

/// The kill switch as a toggle: on while ``KillSwitchIdentity/path`` exists.
///
/// The payload checks the file every time an entry would open the springboard, so a change takes
/// effect without restarting the Dock. Read from disk on every refresh rather than remembered — the
/// file is also created from a terminal, and a restart deletes it.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "KillSwitchController")
@Observable
@MainActor
public final class KillSwitchController {
    /// Whether the system's Apps opens instead of the springboard.
    public private(set) var isEngaged: Bool = false

    /// Most recent failure, cleared on the next successful change. For display.
    public private(set) var lastErrorDescription: String?

    @ObservationIgnored
    private let path: String

    public init(path: String = KillSwitchIdentity.path) {
        self.path = path
        refreshStatus()
    }

    public func refreshStatus() {
        isEngaged = FileManager.default.fileExists(atPath: path)
    }

    public func setEngaged(_ shouldEngage: Bool) {
        defer { refreshStatus() }
        guard shouldEngage != FileManager.default.fileExists(atPath: path) else {
            lastErrorDescription = nil
            return
        }
        do {
            if shouldEngage {
                try Data().write(to: URL(fileURLWithPath: path))
            } else {
                try FileManager.default.removeItem(atPath: path)
            }
            lastErrorDescription = nil
            #log(.info, "Kill switch \(shouldEngage ? "engaged" : "released", privacy: .public)")
        } catch {
            lastErrorDescription = "Could not \(shouldEngage ? "create" : "remove") \(path): \(error.localizedDescription)"
            #log(.error, "Could not change the kill switch: \(error.localizedDescription, privacy: .public)")
        }
    }
}
