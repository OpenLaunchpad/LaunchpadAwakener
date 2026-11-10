import Foundation
import LaunchpadAwakenerShared
import Testing
import TestingSupport
import XPC
@testable import LaunchpadAwakenerTextInputCore

/// The helper's end of the channel: which session it serves as the Dock's, what reaches the service, and what
/// it reports back. Each test listens anonymously; sessions to the endpoint stand in for payloads in Docks.
@Suite("The helper's connection to the Dock", .timeLimit(.minutes(1)))
@MainActor
struct TextInputPeerListenerTests {
    /// A payload's session to the helper, keeping what the helper reports and whether the session ended.
    private final class PayloadSession {
        let session: XPCSession
        let changes: Recorder<TextInputChange>
        private let cancellations: Recorder<String>

        init(endpoint: XPCEndpoint) throws {
            let changes = Recorder<TextInputChange>()
            let cancellations = Recorder<String>()
            session = try XPCSession(
                endpoint: endpoint,
                incomingMessageHandler: { (change: TextInputChange) -> (any Encodable)? in
                    changes.append(change)
                    return nil
                },
                cancellationHandler: { error in
                    cancellations.append(error.debugDescription)
                }
            )
            self.changes = changes
            self.cancellations = cancellations
        }

        var wasCancelled: Bool {
            !cancellations.recorded.isEmpty
        }

        func request<Reply: Decodable & Sendable>(
            _ request: TextInputRequest,
            as replyType: Reply.Type,
            isolation: isolated (any Actor)? = #isolation
        ) async throws -> Reply {
            try await sendExpectingReply(request, over: session, as: replyType)
        }

        /// Asks for something with a reply, so that once it returns this session is the Dock's.
        func becomeServedPeer(isolation: isolated (any Actor)? = #isolation) async throws {
            _ = try await request(.end, as: TextInputEnding.self)
        }

        func cancel() {
            session.cancel(reason: "The test is over")
        }
    }

    private static let configuration = TextInputFieldConfiguration(
        isSearchField: false,
        string: "Utilities",
        selectsAll: true,
        hasFocus: true,
        width: 180,
        height: 20,
        fontSize: 12,
        screenLeft: 640,
        screenTop: 412
    )

    @Test("the Dock's request reaches the service, and the service's answer goes back")
    func requestAndAnswer() async throws {
        let listener = TextInputPeerListener(peerPolicy: .anyPeer)
        var received: [TextInputRequest] = []
        listener.requestHandler = { request in
            received.append(request)
            return TextInputHosting(contextIdentifier: 0x5D21, processIdentifier: 4182, windowNumber: 917)
        }
        let dock = try PayloadSession(endpoint: listener.listenAnonymously())
        defer {
            dock.cancel()
            listener.cancel()
        }

        let hosting = try await dock.request(.begin(Self.configuration), as: TextInputHosting.self)

        #expect(hosting == TextInputHosting(contextIdentifier: 0x5D21, processIdentifier: 4182, windowNumber: 917))
        #expect(received == [.begin(Self.configuration)])
    }

    @Test("requests reach the service in the order the Dock sent them")
    func requestsInOrder() async throws {
        let listener = TextInputPeerListener(peerPolicy: .anyPeer)
        var received: [TextInputRequest] = []
        listener.requestHandler = { request in
            received.append(request)
            return request == .end ? TextInputEnding(string: nil) : nil
        }
        let dock = try PayloadSession(endpoint: listener.listenAnonymously())
        defer {
            dock.cancel()
            listener.cancel()
        }

        let burst = (0..<300).map { index in
            index.isMultiple(of: 5) ? TextInputRequest.setFocus(index.isMultiple(of: 2)) : .setString("text \(index)")
        }
        for request in burst {
            try dock.session.send(request)
        }
        try await dock.becomeServedPeer()

        #expect(received == burst + [.end])
    }

    @Test("changes reach the Dock in the order they were reported")
    func changesInOrder() async throws {
        let listener = TextInputPeerListener(peerPolicy: .anyPeer)
        listener.requestHandler = { _ in TextInputEnding(string: nil) }
        let dock = try PayloadSession(endpoint: listener.listenAnonymously())
        defer {
            dock.cancel()
            listener.cancel()
        }
        try await dock.becomeServedPeer()

        let reported = (0..<300).map { index in
            TextInputChange(string: "text \(index)", hasMarkedText: index.isMultiple(of: 3), isEditingComplete: index == 299)
        }
        for change in reported {
            listener.send(change)
        }

        #expect(await waitUntil { dock.changes.recorded.count == reported.count })
        #expect(dock.changes.recorded == reported)
    }

    @Test("a restarted Dock's connection replaces the last, which is let go without ending the hosting")
    func restartedDockReplacesTheLast() async throws {
        let listener = TextInputPeerListener(peerPolicy: .anyPeer)
        listener.requestHandler = { _ in TextInputEnding(string: nil) }
        var peerEndings = 0
        listener.peerDidEnd = {
            peerEndings += 1
        }
        let endpoint = listener.listenAnonymously()
        let firstDock = try PayloadSession(endpoint: endpoint)
        let restartedDock = try PayloadSession(endpoint: endpoint)
        defer {
            firstDock.cancel()
            restartedDock.cancel()
            listener.cancel()
        }

        try await firstDock.becomeServedPeer()
        try await restartedDock.becomeServedPeer()
        let change = TextInputChange(string: "Safari", hasMarkedText: false, isEditingComplete: false)
        listener.send(change)

        #expect(await waitUntil { restartedDock.changes.recorded == [change] })
        #expect(await waitUntil { firstDock.wasCancelled })
        #expect(firstDock.changes.recorded.isEmpty)
        #expect(peerEndings == 0)
    }

    @Test("the Dock going away ends the hosting once")
    func dockGoingAway() async throws {
        let listener = TextInputPeerListener(peerPolicy: .anyPeer)
        listener.requestHandler = { _ in TextInputEnding(string: nil) }
        var peerEndings = 0
        listener.peerDidEnd = {
            peerEndings += 1
        }
        let dock = try PayloadSession(endpoint: listener.listenAnonymously())
        defer { listener.cancel() }
        try await dock.becomeServedPeer()

        dock.cancel()

        #expect(await waitUntil { peerEndings == 1 })
        #expect(!listener.isServingPeer)
    }

    /// The test process is not the Dock, so with the policy the helper ships with, libxpc refuses its session
    /// before anything reaches the service, and a request waiting for its answer fails instead of hanging.
    @Test("a process that is not the Apple-signed Dock is refused")
    func refusesAnythingButTheDock() async throws {
        let listener = TextInputPeerListener(peerPolicy: .appleSignedDock)
        var received: [TextInputRequest] = []
        listener.requestHandler = { request in
            received.append(request)
            return TextInputEnding(string: "what was typed")
        }
        let impostor = try PayloadSession(endpoint: listener.listenAnonymously())
        defer {
            impostor.cancel()
            listener.cancel()
        }

        await #expect(throws: (any Error).self) {
            try await impostor.request(.end, as: TextInputEnding.self)
        }
        #expect(received.isEmpty)
        #expect(!listener.isServingPeer)
    }

    @Test("a message that is not a text input request is reported, and does not make its sender the Dock")
    func undecodableMessage() async throws {
        let listener = TextInputPeerListener(peerPolicy: .anyPeer)
        var undecodableRequests = 0
        listener.undecodableRequestHandler = {
            undecodableRequests += 1
        }
        let payload = try PayloadSession(endpoint: listener.listenAnonymously())
        defer {
            payload.cancel()
            listener.cancel()
        }

        try payload.session.send(["request": "setup", "isSearchField": "yes"])

        #expect(await waitUntil { undecodableRequests == 1 })
        #expect(!listener.isServingPeer)
    }
}
