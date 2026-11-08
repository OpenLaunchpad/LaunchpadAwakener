import Foundation
import LaunchpadAwakenerShared
import OSToolbox
import ServiceManagement

/// The LaunchAgent that hosts the springboard's text fields so that input methods work in them. launchd
/// starts it when the payload in the Dock connects to its Mach service; until it is registered, the
/// springboard edits its fields itself, without input methods.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "TextInputAgent")
@MainActor
public enum TextInputAgent {
    private static var service: SMAppService {
        SMAppService.agent(plistName: TextInputServiceIdentity.agentPropertyListName)
    }

    /// Registers the agent unless it already is; a user who switched it off in Login Items stays switched off.
    public static func registerIfNeeded() {
        let status = service.status
        guard status == .notRegistered || status == .notFound else { return }
        do {
            try service.register()
            #log(.info, "Registered the text input agent")
        } catch {
            #log(.error, "Could not register the text input agent: \(error.localizedDescription, privacy: .public)")
        }
    }
}
