import CoreGraphics
import Foundation
import LaunchpadAwakenerPrivateInterfaces
import LaunchpadAwakenerShared
import OSToolbox
import QuartzCore
import XPC

/// The connection to the text input helper, the LaunchAgent that hosts the springboard's text fields so
/// that input methods work in them, and the events posted to it, as macOS 15's Dock had its
/// `com.apple.dock.ecti` service (`-[ECTextInputLayer _setupConnection]`, `_forwardEvent:`).
///
/// One `XPCSession` at a time, delivering on the main queue. A session ends for good when the helper exits —
/// "the system will make no attempt to reestablish the connection" (`xpc/session.h`) — so the next `begin`
/// opens another, and launchd starts the helper again.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "TextInputHelperClient")
@MainActor
final class TextInputHelperClient {
    /// What showing the hosted field takes, and where its events go.
    typealias Hosting = TextInputHosting

    /// The field as the helper reports it: the text without what is still composing.
    typealias Change = TextInputChange

    /// Where the helper listens.
    enum Destination {
        /// The helper's Mach service, which launchd starts it for.
        case machService(name: String)
        /// A listener's endpoint; for tests.
        case endpoint(XPCEndpoint)
    }

    static let shared = TextInputHelperClient(destination: .machService(name: TextInputServiceIdentity.machServiceName))

    /// Called with every change the helper reports.
    var changeHandler: ((Change) -> Void)?
    /// Called when the helper went away; whatever it hosted is gone.
    var interruptionHandler: (() -> Void)?

    private let destination: Destination
    private var session: XPCSession?
    /// Counts the sessions opened, so that a session's handlers can tell whether it is still the current one.
    private var sessionGeneration = 0

    init(destination: Destination) {
        self.destination = destination
    }

    /// Sets the field up in the helper; `completion` gets what showing it takes, or nil when the helper
    /// cannot host it.
    func begin(
        isSearchField: Bool,
        string: String,
        selectsAll: Bool,
        hasFocus: Bool,
        size: CGSize,
        fontSize: CGFloat,
        screenTopLeft: CGPoint,
        completion: @escaping @MainActor (Hosting?) -> Void
    ) {
        let request = TextInputRequest.begin(TextInputFieldConfiguration(
            isSearchField: isSearchField,
            string: string,
            selectsAll: selectsAll,
            hasFocus: hasFocus,
            width: Double(size.width),
            height: Double(size.height),
            fontSize: Double(fontSize),
            screenLeft: Double(screenTopLeft.x),
            screenTop: Double(screenTopLeft.y)
        ))
        guard let session = currentSession() else {
            completion(nil)
            return
        }
        do {
            try session.send(request) { (result: Result<TextInputHosting, any Error>) in
                TextInputHelperClient.onMainActor {
                    completion(TextInputHelperClient.hosting(from: result))
                }
            }
        } catch {
            #log(.error, "Could not ask the text input helper to host the field: \(error.localizedDescription, privacy: .public)")
            completion(nil)
        }
    }

    func setString(_ string: String) {
        send(.setString(string))
    }

    func setFocus(_ hasFocus: Bool) {
        send(.setFocus(hasFocus))
    }

    /// Commits any composing text and lets the field go; `completion` gets the final text, composing text
    /// included, or nil when the helper did not answer.
    func end(completion: @escaping @MainActor (String?) -> Void) {
        guard let session else {
            completion(nil)
            return
        }
        do {
            try session.send(TextInputRequest.end) { (result: Result<TextInputEnding, any Error>) in
                TextInputHelperClient.onMainActor {
                    completion(try? result.get().string)
                }
            }
        } catch {
            #log(.error, "Could not ask the text input helper to let the field go: \(error.localizedDescription, privacy: .public)")
            completion(nil)
        }
    }

    /// Lets the session go without reporting the helper gone; the next `begin` opens a new one.
    func cancel() {
        sessionGeneration += 1
        session?.cancel(reason: "The Dock let the text input helper go")
        session = nil
    }

    /// A `CALayerHost` showing the helper's field.
    static func makeLayerHost(showing hosting: Hosting) -> CALayer {
        let hostLayer = CALayerHost()
        hostLayer.contextId = hosting.contextIdentifier
        return hostLayer
    }

    /// Posts a copy of `event` to the helper, marked with its window, as 15's Dock did; mouse events also
    /// get `windowLocation`, where they fall in that window, from its top left.
    func post(_ event: CGEvent, to hosting: Hosting, windowLocation: CGPoint? = nil) {
        guard let copiedEvent = event.copy() else { return }
        if let windowField = CGEventField(rawValue: 51) {
            copiedEvent.setIntegerValueField(windowField, value: Int64(hosting.windowNumber))
        }
        if let windowLocation, let setWindowLocation = Self.setWindowLocation {
            setWindowLocation(copiedEvent, windowLocation)
        }
        copiedEvent.postToPid(hosting.processIdentifier)
    }

    // MARK: - The session

    /// A request without a reply, to the helper hosting the field; none goes out without a session, as there
    /// is then no field to update.
    private func send(_ request: TextInputRequest) {
        guard let session else { return }
        do {
            try session.send(request)
        } catch {
            #log(.error, "Could not send a request to the text input helper: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func currentSession() -> XPCSession? {
        if let session {
            return session
        }
        sessionGeneration += 1
        let generation = sessionGeneration
        let incomingMessageHandler: @Sendable (TextInputChange) -> (any Encodable)? = { [weak self] change in
            let client = self
            TextInputHelperClient.onMainActor {
                client?.receive(change, sessionGeneration: generation)
            }
            return nil
        }
        let cancellationHandler: @Sendable (XPCRichError) -> Void = { [weak self] error in
            let client = self
            let reason = error.debugDescription
            TextInputHelperClient.onMainActor {
                client?.sessionDidEnd(sessionGeneration: generation, reason: reason)
            }
        }
        do {
            let newSession = switch destination {
            case .machService(let name):
                try XPCSession(
                    machService: name,
                    targetQueue: .main,
                    incomingMessageHandler: incomingMessageHandler,
                    cancellationHandler: cancellationHandler
                )
            case .endpoint(let endpoint):
                try XPCSession(
                    endpoint: endpoint,
                    targetQueue: .main,
                    incomingMessageHandler: incomingMessageHandler,
                    cancellationHandler: cancellationHandler
                )
            }
            session = newSession
            return newSession
        } catch {
            #log(.info, "The text input helper is not available: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private func receive(_ change: Change, sessionGeneration generation: Int) {
        guard generation == sessionGeneration else { return }
        changeHandler?(change)
    }

    /// The helper exited, refused the Dock, or was never there; launchd starts it again for the next session.
    private func sessionDidEnd(sessionGeneration generation: Int, reason: String) {
        guard generation == sessionGeneration else { return }
        session = nil
        #log(.info, "The text input helper went away: \(reason, privacy: .public)")
        interruptionHandler?()
    }

    private static func hosting(from result: Result<TextInputHosting, any Error>) -> Hosting? {
        let hosting: TextInputHosting
        do {
            hosting = try result.get()
        } catch {
            #log(.info, "The text input helper did not answer; the field is edited here: \(error.localizedDescription, privacy: .public)")
            return nil
        }
        guard hosting.contextIdentifier != 0 else {
            #log(.error, "The text input helper could not host the field")
            return nil
        }
        return hosting
    }

    /// Runs `body` on the main actor: right away on the main queue, where the session delivers, after a hop
    /// anywhere else. Never traps, as a trap here would take the Dock down.
    private nonisolated static func onMainActor(_ body: @escaping @MainActor @Sendable () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(body)
        } else {
            Task { @MainActor in
                body()
            }
        }
    }

    /// `CGEventSetWindowLocation`, which CoreGraphics exports without declaring.
    private typealias SetWindowLocationFunction = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocationFunction? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetWindowLocationFunction.self)
    }()
}
