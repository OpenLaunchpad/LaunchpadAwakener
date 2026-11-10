import Foundation
import LaunchpadAwakenerShared
import Testing
import TestingSupport
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

    static let deletionConfirmationConfiguration = DeletionConfirmationConfiguration(
        iconPNGData: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0xFF]),
        bundlePath: "/Applications/可删测试.app",
        message: "确定要删除应用程序“可删测试”吗？",
        cancelButtonTitle: "取消",
        deleteButtonTitle: "删除",
        iconCenterX: 742.5,
        iconCenterY: 318.25
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
        .presentDeletionConfirmation(deletionConfirmationConfiguration),
        .presentDeletionConfirmation(DeletionConfirmationConfiguration(
            iconPNGData: nil,
            bundlePath: "/Applications/Pages.app",
            message: "Are you sure you want to delete the application “Pages”?",
            cancelButtonTitle: "Cancel",
            deleteButtonTitle: "Delete",
            iconCenterX: -512,
            iconCenterY: 0
        )),
        .dismissDeletionConfirmation,
    ])
    func requestRoundTrip(request: TextInputRequest) async throws {
        #expect(try await Self.echo(request) == request)
    }

    @Test("the helper's answer to showing the deletion confirmation comes back unchanged", arguments: [true, false])
    func deletionConfirmationPresentationRoundTrip(isShown: Bool) async throws {
        let presentation = DeletionConfirmationPresentation(isShown: isShown)

        #expect(try await Self.echo(presentation) == presentation)
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

    @Test("what the helper tells the Dock comes back unchanged", arguments: [
        TextInputHelperMessage.fieldChange(TextInputChange(string: "にほ", hasMarkedText: true, isEditingComplete: false)),
        .fieldChange(TextInputChange(string: "Notes", hasMarkedText: false, isEditingComplete: true)),
        .deletionConfirmationAnswer(.delete),
        .deletionConfirmationAnswer(.cancel),
    ])
    func helperMessageRoundTrip(message: TextInputHelperMessage) async throws {
        #expect(try await Self.echo(message) == message)
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
