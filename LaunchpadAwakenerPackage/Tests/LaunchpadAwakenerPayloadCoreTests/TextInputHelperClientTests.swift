import CoreGraphics
import Foundation
import LaunchpadAwakenerShared
import Testing
import TestingSupport
import XPC
@testable import LaunchpadAwakenerPayloadCore

/// The Dock's side of the text input channel, against a stand-in helper on an anonymous XPC listener in the
/// test process: what the field asks for, what comes back, and what happens when the helper goes away.
@Suite("The client of the text input helper", .timeLimit(.minutes(1)))
@MainActor
struct TextInputHelperClientTests {
    /// Stands in for the helper: answers `begin` and `end` with what it was given, keeps every request, and
    /// can report changes to the Dock or exit.
    private final class StandInHelper {
        /// `XPCSession` is safe to use from any thread, but the SDK declares it `Sendable` only from macOS 26
        /// on, past the package's deployment target.
        private struct SessionBox: @unchecked Sendable {
            let session: XPCSession
        }

        let requests = Recorder<TextInputRequest>()
        private let sessions = Recorder<SessionBox>()
        private let listener: XPCListener

        init(hosting: TextInputHosting, ending: TextInputEnding = TextInputEnding(string: nil)) {
            let requests = requests
            let sessions = sessions
            listener = XPCListener { request in
                let (decision, session): (XPCListener.IncomingSessionRequest.Decision, XPCSession) = request.accept(
                    incomingMessageHandler: { (message: TextInputRequest) -> (any Encodable)? in
                        requests.append(message)
                        switch message {
                        case .begin:
                            return hosting
                        case .end:
                            return ending
                        case .setString, .setFocus:
                            return nil
                        }
                    }
                )
                sessions.append(SessionBox(session: session))
                return decision
            }
        }

        var endpoint: XPCEndpoint {
            listener.endpoint
        }

        var sessionCount: Int {
            sessions.recorded.count
        }

        func report(_ change: TextInputChange) throws {
            try #require(sessions.recorded.last).session.send(change)
        }

        /// Ends every session, as the helper's process exiting does.
        func exit() {
            for box in sessions.recorded {
                box.session.cancel(reason: "The helper exited")
            }
        }

        func stop() {
            listener.cancel()
            exit()
        }
    }

    private static let hosting = TextInputHosting(contextIdentifier: 0x5D21, processIdentifier: 4182, windowNumber: 917)

    private static func begin(_ client: TextInputHelperClient) async -> TextInputHelperClient.Hosting? {
        await withCheckedContinuation { continuation in
            client.begin(
                isSearchField: true,
                string: "Saf",
                selectsAll: false,
                hasFocus: true,
                size: CGSize(width: 216.5, height: 22),
                fontSize: 13,
                screenTopLeft: CGPoint(x: 627.25, y: 61)
            ) { hosting in
                continuation.resume(returning: hosting)
            }
        }
    }

    private static func end(_ client: TextInputHelperClient) async -> String? {
        await withCheckedContinuation { continuation in
            client.end { endedString in
                continuation.resume(returning: endedString)
            }
        }
    }

    @Test("begin sends the field's configuration and gets what showing the hosted field takes")
    func beginGetsHosting() async throws {
        let helper = StandInHelper(hosting: Self.hosting)
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        defer {
            client.cancel()
            helper.stop()
        }

        let hosting = await Self.begin(client)

        #expect(hosting == Self.hosting)
        #expect(helper.requests.recorded == [.begin(TextInputFieldConfiguration(
            isSearchField: true,
            string: "Saf",
            selectsAll: false,
            hasFocus: true,
            width: 216.5,
            height: 22,
            fontSize: 13,
            screenLeft: 627.25,
            screenTop: 61
        ))])
    }

    @Test("a helper that cannot host the field leaves it to the springboard")
    func helperCannotHost() async throws {
        let helper = StandInHelper(hosting: .unavailable)
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        defer {
            client.cancel()
            helper.stop()
        }

        #expect(await Self.begin(client) == nil)
    }

    @Test("a helper that refuses the Dock leaves the field to the springboard and is reported gone")
    func helperRefusesTheDock() async throws {
        let listener = XPCListener { request in
            request.reject(reason: "Not the Dock")
        }
        let client = TextInputHelperClient(destination: .endpoint(listener.endpoint))
        var interruptions = 0
        client.interruptionHandler = {
            interruptions += 1
        }
        defer {
            client.cancel()
            listener.cancel()
        }

        #expect(await Self.begin(client) == nil)
        #expect(await waitUntil { interruptions == 1 })
    }

    @Test("the field's later requests reach the helper after begin, in order, and end gets the final text")
    func requestsInOrder() async throws {
        let helper = StandInHelper(hosting: Self.hosting, ending: TextInputEnding(string: "Notes 笔记"))
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        defer {
            client.cancel()
            helper.stop()
        }

        _ = await Self.begin(client)
        client.setString("Notes")
        client.setFocus(false)
        let endedString = await Self.end(client)

        #expect(endedString == "Notes 笔记")
        #expect(helper.requests.recorded.dropFirst() == [.setString("Notes"), .setFocus(false), .end])
    }

    @Test("ending a field the helper was never asked to host answers right away, without a session")
    func endWithoutSession() async throws {
        let helper = StandInHelper(hosting: Self.hosting)
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        defer {
            client.cancel()
            helper.stop()
        }

        #expect(await Self.end(client) == nil)
        #expect(helper.sessionCount == 0)
    }

    @Test("changes the helper reports reach the field in the order they were reported")
    func changesInOrder() async throws {
        let helper = StandInHelper(hosting: Self.hosting)
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        var received: [TextInputHelperClient.Change] = []
        client.changeHandler = { change in
            received.append(change)
        }
        defer {
            client.cancel()
            helper.stop()
        }
        _ = await Self.begin(client)

        let reported = (0..<200).map { index in
            TextInputChange(string: String(repeating: "あ", count: index), hasMarkedText: !index.isMultiple(of: 4), isEditingComplete: false)
        }
        for change in reported {
            try helper.report(change)
        }

        #expect(await waitUntil { received.count == reported.count })
        #expect(received == reported)
    }

    @Test("the helper going away is reported once, and the next begin reaches a helper started again")
    func helperGoingAway() async throws {
        let helper = StandInHelper(hosting: Self.hosting)
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        var interruptions = 0
        client.interruptionHandler = {
            interruptions += 1
        }
        defer {
            client.cancel()
            helper.stop()
        }
        _ = await Self.begin(client)

        helper.exit()

        #expect(await waitUntil { interruptions == 1 })
        #expect(await Self.begin(client) == Self.hosting)
        #expect(helper.sessionCount == 2)
        #expect(interruptions == 1)
    }
}
