import Foundation
import LaunchpadAwakenerShared
import OSToolbox
import XPC

/// The helper's end of the channel to the payload: listens on the helper's Mach service, keeps the session
/// of the Dock it serves, and hands that Dock's requests to the service on the main actor.
///
/// Only the Dock may talk to the helper, as anything else could read what is typed. Every session gets the
/// peer requirement before it is activated, so libxpc checks each message and cancels a session whose peer
/// does not satisfy it before anything reaches the handler. The requirement goes on the sessions, not on the
/// listener: a listener drops a request that fails its requirement without a trace, and the sessions it
/// creates do not inherit it (`xpc/listener.h`). On the session, a refusal ends it with a reason this logs.
///
/// A session becomes the Dock's with its first request; one from a restarted Dock replaces the last.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "TextInputPeerListener")
@MainActor
final class TextInputPeerListener {
    /// Which peers the listener serves.
    enum PeerPolicy: Sendable {
        /// Any process; for tests.
        case anyPeer
        /// The Dock, which has to be platform code signed as ``TextInputServiceIdentity/dockSigningIdentifier``.
        /// The requirement takes macOS 26; before that every session is rejected, as the payload runs in no
        /// Dock there.
        case appleSignedDock
    }

    /// Requests from the Dock this serves. The returned value is the reply, sent when the request expects one.
    var requestHandler: ((TextInputRequest) -> (any Encodable & Sendable)?)?
    /// The Dock this served went away.
    var peerDidEnd: (() -> Void)?
    /// A message that is not a ``TextInputRequest``: a payload built from other sources than this helper.
    var undecodableRequestHandler: (() -> Void)?

    private let peerPolicy: PeerPolicy
    private var listener: XPCListener?
    /// The session of the Dock this serves.
    private var peer: XPCSession?
    /// Sessions a newer Dock replaced; they end with nothing to report.
    private var replacedPeerIdentifiers: Set<ObjectIdentifier> = []

    init(peerPolicy: PeerPolicy) {
        self.peerPolicy = peerPolicy
    }

    /// Whether a Dock is connected, so that a change can reach it.
    var isServingPeer: Bool {
        peer != nil
    }

    /// Listens on the helper's Mach service.
    func listen(onMachService serviceName: String) throws {
        listener = try XPCListener(
            service: serviceName,
            targetQueue: .main,
            incomingSessionHandler: Self.incomingSessionHandler(peerPolicy: peerPolicy, owner: self)
        )
    }

    /// Listens without a name; a session reaches the listener through the returned endpoint.
    func listenAnonymously() -> XPCEndpoint {
        let listener = XPCListener(
            targetQueue: .main,
            incomingSessionHandler: Self.incomingSessionHandler(peerPolicy: peerPolicy, owner: self)
        )
        self.listener = listener
        return listener.endpoint
    }

    /// Stops listening and lets the Dock's session go.
    func cancel() {
        listener?.cancel()
        listener = nil
        peer?.cancel(reason: "The text input helper stopped listening")
        peer = nil
    }

    /// Tells the Dock this serves, if one is connected: a change to the hosted field, or the button pressed in
    /// the deletion confirmation.
    func send(_ message: TextInputHelperMessage) {
        guard let peer else { return }
        do {
            try peer.send(message)
        } catch {
            #log(.error, "Could not tell the Dock something: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Sessions

    /// Built outside the main actor: the listener calls it on its own, from the target queue.
    private nonisolated static func incomingSessionHandler(
        peerPolicy: PeerPolicy,
        owner: TextInputPeerListener
    ) -> @Sendable (XPCListener.IncomingSessionRequest) -> XPCListener.IncomingSessionRequest.Decision {
        { [weak owner] request in
            if case .appleSignedDock = peerPolicy, #unavailable(macOS 26.0) {
                return request.reject(reason: "Checking the Dock's signature takes macOS 26")
            }
            return request.accept { session in
                if case .appleSignedDock = peerPolicy, #available(macOS 26.0, *) {
                    session.setPeerRequirement(.isPlatformCode(andMatchesSigningIdentifier: TextInputServiceIdentity.dockSigningIdentifier))
                }
                session.setTargetQueue(.main)
                return TextInputPeerSessionHandler(session: session, owner: owner)
            }
        }
    }

    fileprivate func receive(_ request: TextInputRequest?, from session: XPCSession) -> (any Encodable & Sendable)? {
        guard let request else {
            #log(.error, "Received a message that is not a text input request")
            undecodableRequestHandler?()
            return nil
        }
        // A request that passed the signature check: this is the Dock, a restarted one replacing the last.
        if session !== peer {
            if let peer {
                replacedPeerIdentifiers.insert(ObjectIdentifier(peer))
                peer.cancel(reason: "A restarted Dock replaced this connection")
            }
            peer = session
            #log(.info, "The Dock connected")
        }
        return requestHandler?(request)
    }

    fileprivate func sessionDidEnd(_ session: XPCSession, error: XPCRichError) {
        if session === peer {
            #log(.info, "The Dock's connection ended: \(error.debugDescription, privacy: .public)")
            peer = nil
            peerDidEnd?()
        } else if replacedPeerIdentifiers.remove(ObjectIdentifier(session)) == nil {
            // Never the Dock's: refused by the signature check, or gone before it asked for anything.
            #log(.error, "A connection ended before it sent a request from the Apple-signed Dock: \(error.debugDescription, privacy: .public)")
        }
    }
}

/// Reads one session: decodes each message where libxpc delivers it and hands it to the listener on the main
/// actor. The listener's sessions target the main queue, which is where libxpc calls this.
///
/// `@unchecked Sendable` for the session it holds: `XPCSession` is safe to use from any thread, but the SDK
/// declares it `Sendable` only from macOS 26 on, past this package's deployment target.
private final class TextInputPeerSessionHandler: XPCPeerHandler, @unchecked Sendable {
    typealias Input = XPCReceivedMessage
    typealias Output = any Encodable

    private let session: XPCSession
    private weak let owner: TextInputPeerListener?

    init(session: XPCSession, owner: TextInputPeerListener?) {
        self.session = session
        self.owner = owner
    }

    func handleIncomingRequest(_ message: XPCReceivedMessage) -> (any Encodable)? {
        let request = try? message.decode(as: TextInputRequest.self)
        return MainActor.assumeIsolated {
            owner?.receive(request, from: self.session)
        }
    }

    func handleCancellation(error: XPCRichError) {
        MainActor.assumeIsolated {
            owner?.sessionDidEnd(self.session, error: error)
        }
    }
}
