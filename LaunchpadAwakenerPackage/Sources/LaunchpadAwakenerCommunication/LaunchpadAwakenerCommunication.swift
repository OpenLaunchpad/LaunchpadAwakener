import HelperCommunication

public let LaunchpadAwakenerDaemonBundleIdentifier = "com.MxIris.launchpadawakenerd"

public struct SetVisibleRequest: Request, Codable, Sendable {
    public static var identifier: String { "com.MxIris.LaunchpadAwakenerCommunication.SetVisibleRequest" }

    public typealias Response = VoidResponse
    
    public let isVisible: Bool
    public let reason: String

    public init(isVisible: Bool, reason: String) {
        self.isVisible = isVisible
        self.reason = reason
    }
}
