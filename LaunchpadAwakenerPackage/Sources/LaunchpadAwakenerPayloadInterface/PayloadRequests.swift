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

    /// The Dock build, as its build profile names it. Nil when the build has no profile.
    public let dockBuild: DockBuildSummary?

    public init(
        payloadImageUUID: UUID,
        hostProcessIdentifier: pid_t,
        hostProcessName: String,
        hookInstallation: HookInstallation,
        dockBuild: DockBuildSummary?
    ) {
        self.payloadImageUUID = payloadImageUUID
        self.hostProcessIdentifier = hostProcessIdentifier
        self.hostProcessName = hostProcessName
        self.hookInstallation = hookInstallation
        self.dockBuild = dockBuild
    }
}

/// What the payload did about its hooks when it started.
///
/// Every case other than ``installed(hookCount:)`` leaves the Dock untouched: each entry keeps
/// opening the system's Apps.
public enum HookInstallation: Codable, Sendable, Equatable {
    /// The whole batch is in place.
    case installed(hookCount: Int)
    /// The Dock is a build this payload has no profile for.
    case unknownDockBuild(executableUUID: String)
    /// The build is known, but the methods the payload calls do not match their recorded signatures.
    case incompatibleDockMethods
    /// A hook failed validation, so none were installed.
    case failed(description: String)
}

/// The facts a build profile gives about the Dock it describes.
public struct DockBuildSummary: Codable, Sendable, Equatable {
    /// `CFBundleVersion` of Dock.app.
    public let bundleVersion: String
    /// Every macOS release that ships this build, such as `27.2 (26B123)`.
    public let systemReleases: [String]

    public init(bundleVersion: String, systemReleases: [String]) {
        self.bundleVersion = bundleVersion
        self.systemReleases = systemReleases
    }
}
