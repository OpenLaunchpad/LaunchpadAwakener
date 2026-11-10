import Foundation
import LaunchpadAwakenerShared
import Testing
import XPC

/// The messages between the payload and the text input helper, sent through real XPC in this process: an
/// anonymous listener stands in for the helper, a session to its endpoint for the payload.
@Suite("Text input messages over XPC")
struct TextInputMessageTests {
    static let searchFieldConfiguration = TextInputFieldConfiguration(
        isSearchField: true,
        string: "Saf",
        selectsAll: false,
        hasFocus: true,
        width: 216.5,
        height: 22,
        fontSize: 13,
        screenLeft: 627.25,
        screenTop: 61
    )

    /// Answers every message of `Message` with the message itself, so what comes back went through XPC's
    /// encoding twice.
    private static func echo<Message: Codable & Equatable & Sendable>(_ message: Message) async throws -> Message {
        let listener = XPCListener { request in
            request.accept { (received: Message) -> (any Encodable)? in
                received
            }
        }
        let session = try XPCSession(endpoint: listener.endpoint)
        defer {
            session.cancel(reason: "The test is over")
            listener.cancel()
        }
        return try await sendExpectingReply(message, over: session)
    }

    @Test("every request reaches the helper unchanged", arguments: [
        TextInputRequest.begin(searchFieldConfiguration),
        .begin(TextInputFieldConfiguration(
            isSearchField: false,
            string: "Utilities 工具",
            selectsAll: true,
            hasFocus: false,
            width: 180,
            height: 20,
            fontSize: 12,
            screenLeft: 0,
            screenTop: 0
        )),
        .setString("日本語の入力"),
        .setString(""),
        .setFocus(true),
        .setFocus(false),
        .end,
    ])
    func requestRoundTrip(request: TextInputRequest) async throws {
        #expect(try await Self.echo(request) == request)
    }

    @Test("the helper's answer to begin comes back unchanged", arguments: [
        TextInputHosting(contextIdentifier: 0x8F3A_11C2, processIdentifier: 4182, windowNumber: 917),
        .unavailable,
    ])
    func hostingRoundTrip(hosting: TextInputHosting) async throws {
        #expect(try await Self.echo(hosting) == hosting)
    }

    @Test("the helper's answer to end comes back unchanged, with or without text", arguments: [
        TextInputEnding(string: "Utilities 工具"),
        TextInputEnding(string: ""),
        TextInputEnding(string: nil),
    ])
    func endingRoundTrip(ending: TextInputEnding) async throws {
        #expect(try await Self.echo(ending) == ending)
    }

    @Test("a change the helper reports comes back unchanged", arguments: [
        TextInputChange(string: "にほ", hasMarkedText: true, isEditingComplete: false),
        TextInputChange(string: "Notes", hasMarkedText: false, isEditingComplete: true),
    ])
    func changeRoundTrip(change: TextInputChange) async throws {
        #expect(try await Self.echo(change) == change)
    }

    /// The helper has to apply `setString` and `setFocus` in the order the Dock sent them; one-way messages
    /// sent in a burst, then a request with a reply, must all arrive in that order.
    @Test("requests reach the helper in the order they were sent")
    func requestsArriveInOrder() async throws {
        let received = Recorder<TextInputRequest>()
        let listener = XPCListener { request in
            request.accept { (message: TextInputRequest) -> (any Encodable)? in
                received.append(message)
                return message == .end ? TextInputEnding(string: nil) : nil
            }
        }
        let session = try XPCSession(endpoint: listener.endpoint)
        defer {
            session.cancel(reason: "The test is over")
            listener.cancel()
        }

        let burst = (0..<500).map { index in
            index.isMultiple(of: 7) ? TextInputRequest.setFocus(index.isMultiple(of: 2)) : .setString("text \(index)")
        }
        for request in burst {
            try session.send(request)
        }
        _ = try await sendExpectingReply(TextInputRequest.end, over: session, as: TextInputEnding.self)

        #expect(received.recorded == burst + [.end])
    }
}
