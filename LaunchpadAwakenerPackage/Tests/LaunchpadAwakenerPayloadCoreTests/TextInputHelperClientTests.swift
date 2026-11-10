import CoreGraphics
import Foundation
import ImageIO
import LaunchpadAwakenerShared
import LaunchpadAwakenerSpringboardCore
import Testing
import TestingSupport
import XPC
@testable import LaunchpadAwakenerPayloadCore

/// The Dock's side of the text input channel, against a stand-in helper on an anonymous XPC listener in the
/// test process: what the field asks for, what comes back, and what happens when the helper goes away.
@Suite("The client of the text input helper", .timeLimit(.minutes(1)))
@MainActor
struct TextInputHelperClientTests {
    /// Stands in for the helper: answers `begin`, `end` and the deletion confirmation with what it was given,
    /// keeps every request, and can report changes and buttons to the Dock or exit.
    private final class StandInHelper {
        /// `XPCSession` is safe to use from any thread, but the SDK declares it `Sendable` only from macOS 26
        /// on, past the package's deployment target.
        private struct SessionBox: @unchecked Sendable {
            let session: XPCSession
        }

        let requests = Recorder<TextInputRequest>()
        private let sessions = Recorder<SessionBox>()
        private let listener: XPCListener

        init(
            hosting: TextInputHosting,
            ending: TextInputEnding = TextInputEnding(string: nil),
            presentation: DeletionConfirmationPresentation = DeletionConfirmationPresentation(isShown: true)
        ) {
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
                        case .presentDeletionConfirmation:
                            return presentation
                        case .setString, .setFocus, .dismissDeletionConfirmation:
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
            try #require(sessions.recorded.last).session.send(TextInputHelperMessage.fieldChange(change))
        }

        /// A button of the deletion confirmation pressed.
        func press(_ answer: DeletionConfirmationAnswer) throws {
            try #require(sessions.recorded.last).session.send(TextInputHelperMessage.deletionConfirmationAnswer(answer))
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

    // MARK: - The deletion confirmation

    private static let deletionConfirmation = DeletionConfirmationConfiguration(
        iconPNGData: nil,
        bundlePath: "/Applications/可删测试.app",
        message: "确定要删除应用程序“可删测试”吗？",
        cancelButtonTitle: "取消",
        deleteButtonTitle: "删除",
        iconCenterX: 742.5,
        iconCenterY: 318
    )

    private static func presentDeletionConfirmation(_ client: TextInputHelperClient) async -> Bool {
        await withCheckedContinuation { continuation in
            client.presentDeletionConfirmation(deletionConfirmation) { isShown in
                continuation.resume(returning: isShown)
            }
        }
    }

    /// What the springboard asks the Dock's confirmation to show: its icon, words and place.
    private static func confirmationConfiguration(icon: CGImage?) -> SpringboardHostedDeletionConfirmationConfiguration {
        SpringboardHostedDeletionConfirmationConfiguration(
            icon: icon,
            bundleURL: URL(fileURLWithPath: "/Applications/可删测试.app"),
            message: "确定要删除应用程序“可删测试”吗？",
            cancelButtonTitle: "取消",
            deleteButtonTitle: "删除",
            screenIconCenter: CGPoint(x: 742.5, y: 318)
        )
    }

    /// The deletion confirmation on the Dock's side, asking `client`'s helper.
    private static func remoteConfirmation(client: TextInputHelperClient) -> SpringboardRemoteDeletionConfirmation {
        SpringboardRemoteDeletionConfirmation(configuration: confirmationConfiguration(icon: nil), client: client)
    }

    @Test("showing the deletion confirmation sends what it shows, and gets whether it is on screen", arguments: [true, false])
    func presentDeletionConfirmation(isShown: Bool) async throws {
        let helper = StandInHelper(hosting: Self.hosting, presentation: DeletionConfirmationPresentation(isShown: isShown))
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        defer {
            client.cancel()
            helper.stop()
        }

        #expect(await Self.presentDeletionConfirmation(client) == isShown)
        #expect(helper.requests.recorded == [.presentDeletionConfirmation(Self.deletionConfirmation)])
    }

    @Test("a helper that refuses the Dock leaves the springboard to ask itself")
    func presentDeletionConfirmationRefused() async throws {
        let listener = XPCListener { request in
            request.reject(reason: "Not the Dock")
        }
        let client = TextInputHelperClient(destination: .endpoint(listener.endpoint))
        defer {
            client.cancel()
            listener.cancel()
        }

        #expect(await Self.presentDeletionConfirmation(client) == false)
    }

    @Test("the buttons pressed reach the confirmation in order, apart from the field's changes")
    func deletionAnswersInOrder() async throws {
        let helper = StandInHelper(hosting: Self.hosting)
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        var answers: [DeletionConfirmationAnswer] = []
        var changes: [TextInputHelperClient.Change] = []
        client.deletionConfirmationAnswerHandler = { answer in
            answers.append(answer)
        }
        client.changeHandler = { change in
            changes.append(change)
        }
        defer {
            client.cancel()
            helper.stop()
        }
        _ = await Self.presentDeletionConfirmation(client)
        let change = TextInputChange(string: "Safari", hasMarkedText: false, isEditingComplete: false)

        try helper.press(.cancel)
        try helper.report(change)
        try helper.press(.delete)

        #expect(await waitUntil { answers.count == 2 && changes.count == 1 })
        #expect(answers == [.cancel, .delete])
        #expect(changes == [change])
    }

    @Test("dismissing reaches the helper after showing, and needs no session when nothing was shown")
    func dismissDeletionConfirmation() async throws {
        let helper = StandInHelper(hosting: Self.hosting)
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        defer {
            client.cancel()
            helper.stop()
        }

        client.dismissDeletionConfirmation()
        #expect(helper.sessionCount == 0)
        _ = await Self.presentDeletionConfirmation(client)
        client.dismissDeletionConfirmation()
        _ = await Self.end(client)

        #expect(helper.requests.recorded == [.presentDeletionConfirmation(Self.deletionConfirmation), .dismissDeletionConfirmation, .end])
    }

    @Test("the helper going away is reported to the deletion confirmation as well as to the field")
    func helperGoingAwayReachesTheConfirmation() async throws {
        let helper = StandInHelper(hosting: Self.hosting)
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        var fieldInterruptions = 0
        var confirmationInterruptions = 0
        client.interruptionHandler = {
            fieldInterruptions += 1
        }
        client.deletionConfirmationInterruptionHandler = {
            confirmationInterruptions += 1
        }
        defer {
            client.cancel()
            helper.stop()
        }
        _ = await Self.presentDeletionConfirmation(client)

        helper.exit()

        #expect(await waitUntil { confirmationInterruptions == 1 })
        #expect(fieldInterruptions == 1)
    }

    /// Shows the Dock's confirmation and waits until the helper's answer to showing it has come back: the
    /// answer to `end`, sent after it on the same session, comes back after it.
    private static func presentAndWait(_ confirmation: SpringboardRemoteDeletionConfirmation, client: TextInputHelperClient) async {
        confirmation.present()
        _ = await end(client)
    }

    @Test("the Dock's confirmation reports the button pressed once the helper shows it, and nothing after it is dismissed")
    func remoteConfirmationAnswers() async throws {
        let helper = StandInHelper(hosting: Self.hosting)
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        defer {
            client.cancel()
            helper.stop()
        }
        let confirmation = Self.remoteConfirmation(client: client)
        var choices: [SpringboardDeletionChoice] = []
        var failures = 0
        confirmation.answerHandler = { choice in
            choices.append(choice)
        }
        confirmation.presentationDidFail = {
            failures += 1
        }

        await Self.presentAndWait(confirmation, client: client)
        try helper.press(.delete)
        #expect(await waitUntil { choices == [.delete] })
        confirmation.dismiss()
        try helper.press(.cancel)
        // The button pressed after the dismissal has come back by the time the answer to `end` does.
        _ = await Self.end(client)

        #expect(choices == [.delete])
        #expect(failures == 0)
        #expect(helper.requests.recorded == [
            .presentDeletionConfirmation(SpringboardRemoteDeletionConfirmation.message(for: confirmation.configuration)),
            .end,
            .dismissDeletionConfirmation,
            .end,
        ])
    }

    @Test("the Dock's confirmation leaves the question to the springboard when the helper cannot show it")
    func remoteConfirmationCannotBeShown() async throws {
        let helper = StandInHelper(hosting: Self.hosting, presentation: DeletionConfirmationPresentation(isShown: false))
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        defer {
            client.cancel()
            helper.stop()
        }
        let confirmation = Self.remoteConfirmation(client: client)
        var failures = 0
        var interruptions = 0
        var sessionEndings = 0
        confirmation.presentationDidFail = {
            failures += 1
        }
        confirmation.interruptionHandler = {
            interruptions += 1
        }
        client.interruptionHandler = {
            sessionEndings += 1
        }

        await Self.presentAndWait(confirmation, client: client)
        #expect(failures == 1)
        helper.exit()
        #expect(await waitUntil { sessionEndings == 1 })

        #expect(failures == 1)
        #expect(interruptions == 0)
    }

    @Test("the helper going away before it answers leaves the question to the springboard, once")
    func remoteConfirmationHelperGoneBeforeShowing() async throws {
        let listener = XPCListener { request in
            request.reject(reason: "Not the Dock")
        }
        let client = TextInputHelperClient(destination: .endpoint(listener.endpoint))
        defer {
            client.cancel()
            listener.cancel()
        }
        let confirmation = Self.remoteConfirmation(client: client)
        var failures = 0
        var interruptions = 0
        var sessionEndings = 0
        confirmation.presentationDidFail = {
            failures += 1
        }
        confirmation.interruptionHandler = {
            interruptions += 1
        }
        client.interruptionHandler = {
            sessionEndings += 1
        }

        confirmation.present()

        #expect(await waitUntil { failures == 1 && sessionEndings == 1 })
        #expect(failures == 1)
        #expect(interruptions == 0)
    }

    @Test("the helper going away while it shows the confirmation ends the question")
    func remoteConfirmationInterrupted() async throws {
        let helper = StandInHelper(hosting: Self.hosting)
        let client = TextInputHelperClient(destination: .endpoint(helper.endpoint))
        defer {
            client.cancel()
            helper.stop()
        }
        let confirmation = Self.remoteConfirmation(client: client)
        var failures = 0
        var interruptions = 0
        confirmation.presentationDidFail = {
            failures += 1
        }
        confirmation.interruptionHandler = {
            interruptions += 1
        }
        await Self.presentAndWait(confirmation, client: client)

        helper.exit()

        #expect(await waitUntil { interruptions == 1 })
        #expect(failures == 0)
    }

    @Test("the Dock sends the icon as PNG of the same size, and the bundle's path, the words and the place as they are")
    func remoteConfirmationMessage() throws {
        let icon = try #require(Self.makeIcon(side: 48))

        let message = SpringboardRemoteDeletionConfirmation.message(for: Self.confirmationConfiguration(icon: icon))

        let pngData = try #require(message.iconPNGData)
        let source = try #require(CGImageSourceCreateWithData(pngData as CFData, nil))
        #expect(CGImageSourceGetType(source) as String? == "public.png")
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == 48 && decoded.height == 48)
        #expect(message.bundlePath == "/Applications/可删测试.app")
        #expect(message.message == "确定要删除应用程序“可删测试”吗？")
        #expect(message.cancelButtonTitle == "取消")
        #expect(message.deleteButtonTitle == "删除")
        #expect(message.iconCenterX == 742.5 && message.iconCenterY == 318)
        #expect(SpringboardRemoteDeletionConfirmation.message(for: Self.confirmationConfiguration(icon: nil)).iconPNGData == nil)
    }

    private static func makeIcon(side: Int) -> CGImage? {
        guard
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
            let context = CGContext(
                data: nil,
                width: side,
                height: side,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else { return nil }
        context.setFillColor(CGColor(red: 0.2, green: 0.5, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        return context.makeImage()
    }
}
