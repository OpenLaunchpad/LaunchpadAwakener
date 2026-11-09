import Foundation
import HelperClient
import HelperCommunication
import HelperPeer
import InjectedEndpointRegistryServiceInterface
import LaunchpadAwakenerPayloadInterface
import LaunchpadAwakenerShared

/// The app's side of the direct channel to an injected payload.
///
/// One instance per host process. The app keeps these in ``PayloadInjectionCoordinator`` so a
/// relaunch can pick up the payloads that are still resident instead of pretending nothing is
/// injected — which made re-injecting look like the fix when a mapped image cannot be loaded twice
/// and nothing would happen.
///
/// ## Why the app is the client
///
/// The payload holds the listener and the app connects to it. The party that outlives the other
/// should own the listener, and here that is the payload: it lives as long as the Dock, while the app
/// comes and goes.
actor PayloadChannel {
    let hostProcessIdentifier: pid_t

    private var peer: HelperPeerClient?

    private init(hostProcessIdentifier: pid_t, peer: HelperPeerClient?) {
        self.hostProcessIdentifier = hostProcessIdentifier
        self.peer = peer
    }

    // MARK: - Opening

    /// Prepares a channel for a host that is about to be injected.
    ///
    /// Must complete *before* the payload is injected. The payload looks the app's endpoint up by
    /// the host's process identifier as it starts, so registering afterwards would mean the payload
    /// finds nothing and comes up with no channel at all.
    ///
    /// Returns a channel that is not connected yet: the payload completes the handshake from its
    /// side once it is running. ``waitUntilConnected(timeout:)`` waits for that.
    static func prepare(forHostProcessIdentifier hostProcessIdentifier: pid_t) async throws -> PayloadChannel {
        let peer = try await HelperPeerClient(
            machServiceName: InjectionServiceIdentity.machServiceName,
            isPrivilegedHelperTool: true,
            identifier: String(hostProcessIdentifier)
        )
        try await peer.activate()
        return PayloadChannel(hostProcessIdentifier: hostProcessIdentifier, peer: peer)
    }

    /// Reconnects to a payload that is already running, using the endpoint it published.
    ///
    /// This path skips the handshake entirely — the payload's listener is already up, so the app
    /// connects straight to it and the library swaps the payload's peer connection in place.
    static func reconnect(to endpointInfo: InjectedEndpointInfo) async throws -> PayloadChannel {
        let peer = try await HelperPeerClient(
            machServiceName: InjectionServiceIdentity.machServiceName,
            isPrivilegedHelperTool: true,
            identifier: String(endpointInfo.pid),
            serverEndpoint: endpointInfo.endpoint
        )
        try await peer.activate()
        return PayloadChannel(hostProcessIdentifier: endpointInfo.pid, peer: peer)
    }

    /// Waits for the payload to complete the handshake after being injected.
    ///
    /// The `.connected` transition arrives asynchronously — the client half of the handshake
    /// finishes the moment the payload connects back, which is some milliseconds after injection
    /// returns. Returns false on timeout rather than throwing: a payload that never called home is
    /// a fact to display, not an error to propagate.
    func waitUntilConnected(timeout: Duration = .seconds(5)) async -> Bool {
        guard let peer else { return false }

        let isConnected = try? await withTimeLimit(timeout) {
            for await state in peer.stateStream {
                switch state {
                case .connected:
                    return true
                case .disconnected, .cancelled:
                    return false
                case .connecting:
                    continue
                }
            }
            return false
        }
        return isConnected ?? false
    }

    // MARK: - Requests

    /// How long a status request may take. The payload answers from an actor of its own in
    /// milliseconds; a Dock that is hung or stopped never answers, and without a limit one such Dock
    /// would stall the window's whole refresh loop.
    static let statusTimeLimit = Duration.seconds(2)

    func fetchStatus() async throws -> PayloadStatus {
        guard let peer else { throw ChannelError.notConnected }
        return try await withTimeLimit(Self.statusTimeLimit) {
            try await peer.send(PayloadStatusRequest())
        }
    }

    /// How long the layout may take to come back. A few hundred applications are tens of kilobytes.
    static let layoutSnapshotTimeLimit = Duration.seconds(5)
    /// How long a batch of layout edits may take: the library stores them in one transaction, then
    /// publishes the layout to the springboard.
    static let layoutEditTimeLimit = Duration.seconds(15)

    func fetchLayout(knownRevision: Int?) async throws -> LayoutSnapshotReply {
        guard let peer else { throw ChannelError.notConnected }
        return try await withTimeLimit(Self.layoutSnapshotTimeLimit) {
            try await peer.send(LayoutSnapshotRequest(knownRevision: knownRevision))
        }
    }

    func applyLayoutEdits(_ edits: [LayoutEdit], expectedRevision: Int) async throws -> LayoutEditReply {
        guard let peer else { throw ChannelError.notConnected }
        return try await withTimeLimit(Self.layoutEditTimeLimit) {
            try await peer.send(LayoutEditRequest(expectedRevision: expectedRevision, edits: edits))
        }
    }

    func close() async {
        await peer?.cancel()
        peer = nil
    }

    enum ChannelError: LocalizedError {
        case notConnected

        var errorDescription: String? {
            switch self {
            case .notConnected:
                return "No channel to the injected payload."
            }
        }
    }
}

/// Reads the daemon's registry of injected processes.
struct InjectedPayloadRegistry {
    let daemonController: PrivilegedDaemonController

    /// Every host the daemon believes has a live payload in it.
    ///
    /// The daemon watches each registered process and drops the entry when it exits, so a Dock
    /// restart cleans up after itself and this never returns an endpoint belonging to a dead
    /// process.
    @MainActor
    func liveEndpoints() async throws -> [InjectedEndpointInfo] {
        try await daemonController.send(request: FetchAllInjectedEndpointsRequest()).endpoints
    }

    @MainActor
    func forget(hostProcessIdentifier: pid_t) async {
        _ = try? await daemonController.send(request: RemoveInjectedEndpointRequest(pid: hostProcessIdentifier))
    }
}
