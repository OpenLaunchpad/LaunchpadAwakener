import Foundation
import HelperCommunication

/// What the app asks the payload, and what it gets back.
///
/// Both sides link this module and nothing else of each other's, so the wire contract is one file
/// rather than something to reconstruct from two implementations.

/// Asks the payload what it is doing inside its host.
public struct PayloadStatusRequest: Codable, Sendable, Request {
    public typealias Response = PayloadStatus

    public static let identifier = "com.MxIris.LaunchpadAwakener.PayloadStatus"

    public init() {}
}

/// A snapshot of one injected payload.
public struct PayloadStatus: Codable, Sendable, Equatable {
    /// `LC_UUID` of the payload image actually resident in the host.
    ///
    /// A payload is a mapped image and cannot be unloaded, so rebuilding it and re-injecting
    /// silently leaves the old code running. The app compares this against the UUIDs of the payload
    /// in its own bundle — a value the linker derives from the code, so unlike a version number it
    /// cannot be forgotten when the payload changes.
    public let payloadImageUUID: UUID

    /// Process the payload is running inside.
    public let hostProcessIdentifier: pid_t

    /// Name of that process, for display.
    public let hostProcessName: String

    /// What became of the hooks.
    public let hookInstallation: HookInstallation

    /// Which Dock this payload is attached to, as the host reports itself.
    public let dockBuild: DockBuildSummary

    /// Whether the globals the replica needs could be reached when this snapshot was taken.
    ///
    /// Worked out on being asked, not when the payload started: the Dock may not have built its
    /// singletons by then, and a snapshot taken a second later would say something different.
    public let dockGlobalsReachability: DockGlobalsReachability

    public init(
        payloadImageUUID: UUID,
        hostProcessIdentifier: pid_t,
        hostProcessName: String,
        hookInstallation: HookInstallation,
        dockBuild: DockBuildSummary,
        dockGlobalsReachability: DockGlobalsReachability
    ) {
        self.payloadImageUUID = payloadImageUUID
        self.hostProcessIdentifier = hostProcessIdentifier
        self.hostProcessName = hostProcessName
        self.hookInstallation = hookInstallation
        self.dockBuild = dockBuild
        self.dockGlobalsReachability = dockGlobalsReachability
    }
}

/// What the payload did about its hooks when it started.
///
/// Every case other than ``installed(hookCount:)`` leaves the Dock untouched: each entry keeps
/// opening the system's Apps.
public enum HookInstallation: Codable, Sendable, Equatable {
    /// The whole batch is in place.
    case installed(hookCount: Int)
    /// The methods the payload calls do not match the signatures it recorded for them.
    case incompatibleDockMethods
    /// A hook failed validation, so none were installed.
    case failed(description: String)
}

/// Whether the payload can reach the host globals the replica needs, at the moment it was asked.
///
/// Kept apart from ``HookInstallation`` because neither decides the other. The hooks decide where the
/// Launchpad key goes; the globals give the geometry and the material needed to sit against the Dock.
/// Without them the replica still opens — the Dock just does not slide away, the glass background is
/// not drawn, and the Dock's thickness falls back to a default.
public enum DockGlobalsReachability: Codable, Sendable, Equatable {
    /// Every global the replica needs was found.
    case reachable
    /// What could not be found, named the way a person would read it.
    case unreachable(missingClassNames: [String])
}

/// Which Dock the payload is attached to, as that Dock reports itself.
public struct DockBuildSummary: Codable, Sendable, Equatable {
    /// `CFBundleVersion` of Dock.app, read from the host's own bundle.
    public let bundleVersion: String
    /// The macOS this Dock is running on, such as `27.2 (26B123)`.
    public let systemRelease: String

    public init(bundleVersion: String, systemRelease: String) {
        self.bundleVersion = bundleVersion
        self.systemRelease = systemRelease
    }
}
