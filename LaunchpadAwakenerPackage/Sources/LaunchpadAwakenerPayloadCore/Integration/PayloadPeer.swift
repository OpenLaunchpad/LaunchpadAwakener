import Foundation
import MachO
import HelperClient
import HelperPeer
import InjectedEndpointRegistryServiceInterface
import LaunchpadAwakenerPayloadInterface
import LaunchpadAwakenerShared
import OSToolbox

/// The payload's side of the direct channel to the app.
///
/// ## What this is for
///
/// Without it the app cannot tell an injected Dock from an uninjected one. It only knows what *it*
/// injected during the current run, so relaunching the app makes a perfectly good payload invisible:
/// the window says "not injected", and injecting again does nothing, because a mapped image cannot
/// be loaded twice. This publishes an endpoint the app can find after a restart, and answers
/// questions about what the payload is actually doing — above all whether its hooks went in, which
/// on a Dock build without a profile they do not.
///
/// ## Shape
///
/// The payload is the *server* and the app is the client: the party that outlives the other holds
/// the listener. Payloads survive app restarts; apps do not survive Dock restarts. Two paths reach it:
///
/// - **First injection.** The app registers its own endpoint with the daemon under the Dock's process
///   identifier before injecting. This peer looks that up, connects back, and publishes its listener
///   endpoint to the daemon's injected-endpoint registry.
/// - **After the app restarts.** The app reads the registry, finds this endpoint, and connects to it
///   directly. No handshake — the library swaps the peer connection in place.
///
/// ## Failure is not fatal
///
/// Every failure here is logged and swallowed. The hooks are the product; this channel is how the
/// app's window stays honest about them. A payload whose hooks are in must not be taken down because
/// the daemon was unreachable for a moment, and one injected by something other than the app has no
/// client waiting and simply gets no channel.
///
/// Logged at `default` rather than `info`: `info` is not persisted, and a channel that failed to open
/// is noticed minutes later, by which time an `info` line has scrolled away. It runs once per
/// injection, so the volume does not matter.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "PayloadPeer")
actor PayloadPeer {
    static let shared = PayloadPeer()

    private var peer: HelperPeerServer?

    private var hookInstallation: HookInstallation = .installed(hookCount: 0)

    private init() {}

    func start(hookInstallation: HookInstallation) async {
        self.hookInstallation = hookInstallation

        let hostProcessIdentifier = ProcessInfo.processInfo.processIdentifier
        #log(.default, "Opening the channel to the app…")

        do {
            let peer = try await HelperPeerServer(
                machServiceName: InjectionServiceIdentity.machServiceName,
                isPrivilegedHelperTool: true,
                identifier: String(hostProcessIdentifier)
            )

            // Handlers first, activation second. `activate()` tells the app this side is ready, and
            // the app answers by asking for status immediately; installing handlers afterwards would
            // race that first request.
            installHandlers(on: peer)
            try await peer.activate()
            self.peer = peer

            await publishEndpoint(of: peer, hostProcessIdentifier: hostProcessIdentifier)
            #log(.default, "Channel to the app is open")
        } catch {
            #log(.error, "No channel to the app: \(error.localizedDescription, privacy: .public). Hooks are unaffected.")
        }
    }

    private nonisolated func installHandlers(on peer: HelperPeerServer) {
        peer.setMessageHandler(PayloadStatusRequest.self) { _ in
            await PayloadPeer.shared.currentStatus()
        }
        peer.setMessageHandler(LayoutSnapshotRequest.self) { request in
            await LayoutOrganizerService.reply(to: request)
        }
        peer.setMessageHandler(LayoutEditRequest.self) { request in
            await LayoutOrganizerService.reply(to: request)
        }
    }

    private func currentStatus() -> PayloadStatus {
        PayloadStatus(
            payloadImageUUID: Self.payloadImageUUID,
            hostProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            hostProcessName: ProcessInfo.processInfo.processName,
            hookInstallation: hookInstallation,
            dockBuild: DockBuildProfile.current.map { profile in
                DockBuildSummary(bundleVersion: profile.bundleVersion, systemReleases: profile.systemReleases)
            }
        )
    }

    /// `LC_UUID` of this payload's own image, which the app compares with the copy in its bundle.
    ///
    /// `#dsohandle` is the header of the image this code is linked into — the payload framework,
    /// since the package's modules are linked into it statically. All zeros, which no linker writes,
    /// when the image has no UUID; the app then reports the payload as outdated rather than current.
    private static let payloadImageUUID: UUID = {
        let header = #dsohandle.assumingMemoryBound(to: mach_header.self)
        return MachOImageInspector.uuid(ofImageWithHeader: header) ?? UUID(uuid: uuid_t(0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }()

    /// Publishes the listener endpoint so the app can reconnect directly after a restart.
    ///
    /// The daemon drops the entry when this process exits, so a Dock restart cleans up after itself
    /// and the app never has to tell a live endpoint from one belonging to a dead process.
    private func publishEndpoint(of peer: HelperPeerServer, hostProcessIdentifier: pid_t) async {
        do {
            let helperClient = HelperClient()
            try await helperClient.connectToTool(
                machServiceName: InjectionServiceIdentity.machServiceName,
                isPrivilegedHelperTool: true
            )
            try await helperClient.sendToTool(
                request: RegisterInjectedEndpointRequest(
                    pid: hostProcessIdentifier,
                    appName: ProcessInfo.processInfo.processName,
                    bundleIdentifier: Bundle.main.bundleIdentifier ?? "",
                    endpoint: await peer.listenerEndpoint
                )
            )
            #log(.default, "Published endpoint for \(hostProcessIdentifier, privacy: .public)")
        } catch {
            // The app can still reach this payload for the rest of its own run; it just will not
            // find it again after a relaunch.
            #log(.error, "Could not publish endpoint: \(error.localizedDescription, privacy: .public)")
        }
    }
}
