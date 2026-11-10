import AppKit
import LaunchpadAwakenerAppKitPrivateInterfaces
import LaunchpadAwakenerShared
import OSToolbox

/// Hosts the one field the payload asks for — the springboard's search field or an open folder's name,
/// which are never edited at once — following macOS 15's `-[ECTIHelperDelegate _handleSetupMessage:forPeer:]`
/// and `_handleSetupMiniViewMessage:forPeer:`. Also shows the confirmation for deleting an application, as
/// 15's `com.apple.dock.ecap` service did (``DeletionConfirmationPopover``).
///
/// The field lives in the Dock tile's mini view window, which can be key and is kept transparent on screen
/// (``makeInvisibleOnScreen(_:)``). The payload shows that window's layer-hosting context in the Dock and
/// posts the Dock's keys and clicks to this process; this service reports the text back. The requests come
/// through ``TextInputPeerListener``.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "TextInputService")
@MainActor
final class TextInputService: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = TextInputService()

    /// Only the Dock shows the field; anything else could read what is typed.
    private let peerListener = TextInputPeerListener(peerPolicy: .appleSignedDock)
    private let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
    private let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
    private let fieldEditor = TextInputFieldEditor()
    private let deletionConfirmation = DeletionConfirmationPopover()
    private var isSearchField = true
    private var lastReportedString = ""
    private var lastReportedHasMarkedText = false
    /// Whether the field is set up for the payload's last `begin`: only then is its text the payload's.
    private var isHosting = false
    /// The executable as it was when this process started; a deployment replaces it.
    private let executableIdentity = TextInputService.currentExecutableIdentity()

    func start() {
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.focusRingType = .none
        textField.textColor = .white
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.delegate = self
        containerView.addSubview(textField)
        // Launchpad's fields are white on a dark backdrop; the dark look gives the caret and the selection
        // 15's colours.
        containerView.appearance = NSAppearance(named: .darkAqua)
        fieldEditor.isFieldEditor = true
        fieldEditor.markedTextDidChange = { [weak self] in
            self?.reportState(isEditingComplete: false)
        }

        // Only the Dock closes the confirmation; a button just says which it was, as ecap's did.
        deletionConfirmation.answerHandler = { [weak self] answer in
            self?.peerListener.send(.deletionConfirmationAnswer(answer))
        }

        peerListener.requestHandler = { [weak self] request in
            self?.handle(request)
        }
        // The Dock went away: keep nothing composing, let the field go, and take the confirmation down.
        peerListener.peerDidEnd = { [weak self] in
            self?.end()
            self?.deletionConfirmation.dismiss()
        }
        peerListener.undecodableRequestHandler = { [weak self] in
            self?.exitIfReplaced()
        }
        do {
            try peerListener.listen(onMachService: TextInputServiceIdentity.machServiceName)
            #log(.info, "Listening on \(TextInputServiceIdentity.machServiceName, privacy: .public)")
        } catch {
            #log(.error, "Could not listen on \(TextInputServiceIdentity.machServiceName, privacy: .public): \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Requests

    private func handle(_ request: TextInputRequest) -> (any Encodable & Sendable)? {
        switch request {
        case .begin(let configuration):
            return begin(with: configuration)
        case .setString(let string):
            setString(string)
            return nil
        case .setFocus(let hasFocus):
            showCaret(hasFocus)
            return nil
        case .end:
            // The final text, composing text included, for a rename that ended while text was composing;
            // none when this field was never set up, as the text left is then another field's.
            return TextInputEnding(string: end())
        case .presentDeletionConfirmation(let configuration):
            return DeletionConfirmationPresentation(isShown: deletionConfirmation.present(configuration))
        case .dismissDeletionConfirmation:
            deletionConfirmation.dismiss()
            restoreHostedFieldWindowAsKey()
            return nil
        }
    }

    /// The popover's window took the key status from the field's while it showed; a field still hosted, the
    /// search field say, gets it back so that the keys the Dock forwards land in it again.
    private func restoreHostedFieldWindowAsKey() {
        guard isHosting, let window = containerView.window else { return }
        window.makeKey()
    }

    private func begin(with configuration: TextInputFieldConfiguration) -> TextInputHosting {
        isHosting = false
        // A deployment replaced this executable: the new one hosts the field from the next opening on.
        if exitIfReplaced() {
            return .unavailable
        }
        // A field editor keeps what it was set up with — the search field's alignment, say — so the new
        // field starts its editing afresh.
        containerView.window?.makeFirstResponder(nil)
        isSearchField = configuration.isSearchField
        let string = configuration.string
        let width = configuration.width
        let height = configuration.height
        let fontSize = configuration.fontSize
        textField.font = NSFont.systemFont(ofSize: fontSize, weight: .light)
        textField.alignment = isSearchField ? .natural : .center
        containerView.setFrameSize(NSSize(width: width, height: height))
        // 15 set the field 3 points (search) or 2 (rename) below the view's bottom edge.
        textField.frame = NSRect(x: 0, y: isSearchField ? -3 : -2, width: width, height: height)
        fieldEditor.inputContext?.discardMarkedText()
        textField.stringValue = string
        lastReportedString = string
        lastReportedHasMarkedText = false

        guard let window = showMiniViewWindow() else {
            return .unavailable
        }
        // Candidate windows are placed from where the window is on screen: where the field is shown.
        let screenLeft = configuration.screenLeft
        let screenTop = configuration.screenTop
        let zeroScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        window.setFrame(NSRect(x: screenLeft, y: zeroScreenHeight - screenTop - height, width: width, height: height), display: false)
        window.makeKey()
        window.makeFirstResponder(textField)
        fieldEditor.alignment = textField.alignment
        if configuration.selectsAll {
            textField.selectText(nil)
        } else {
            fieldEditor.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        }
        showCaret(configuration.hasFocus)
        Self.setRemoteViewActivation(true)
        let contextIdentifier = Self.layerHostingContextIdentifier(of: window)
        isHosting = contextIdentifier != 0
        #log(.info, "Hosting the \(self.isSearchField ? "search" : "rename", privacy: .public) field, \(width, privacy: .public)×\(height, privacy: .public)")
        guard isHosting else { return .unavailable }
        return TextInputHosting(
            contextIdentifier: contextIdentifier,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            windowNumber: window.windowNumber
        )
    }

    /// Without the focus the field shows no caret, as 15's did not. It stays the first responder, so that
    /// the next key forwarded to it still lands.
    private func showCaret(_ hasFocus: Bool) {
        fieldEditor.insertionPointColor = hasFocus ? .white : .clear
    }

    /// Exits when a deployment replaced this executable, so that launchd starts the new one on the next
    /// request; that request's answer goes out first. Asked on every `begin`, and on a request this build
    /// cannot read, which a newer payload sends when the messages changed. Returns whether it is exiting.
    @discardableResult
    private func exitIfReplaced() -> Bool {
        guard Self.currentExecutableIdentity() != executableIdentity else { return false }
        #log(.info, "A new build replaced the helper; exiting so that launchd starts that one")
        DispatchQueue.main.async {
            exit(EXIT_SUCCESS)
        }
        return true
    }

    /// The executable's file number and modification time; a deployment changes both.
    private static func currentExecutableIdentity() -> String? {
        guard
            let executablePath = Bundle.main.executablePath,
            let attributes = try? FileManager.default.attributesOfItem(atPath: executablePath)
        else { return nil }
        let fileNumber = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        let modificationTime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        return "\(fileNumber)-\(modificationTime)"
    }

    private func setString(_ string: String) {
        fieldEditor.inputContext?.discardMarkedText()
        textField.stringValue = string
        fieldEditor.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        lastReportedString = string
        lastReportedHasMarkedText = false
    }

    /// Composing text is kept, as clicking away from any text field keeps it; the final text goes back first.
    /// Returns that text, taken before the window goes, when the field was set up for the payload.
    @discardableResult
    private func end() -> String? {
        defer { isHosting = false }
        if fieldEditor.hasMarkedText() {
            fieldEditor.unmarkText()
        }
        reportState(isEditingComplete: false)
        let endedString = isHosting ? fieldEditor.string : nil
        Self.setRemoteViewActivation(false)
        NSApp.dockTile._setMiniViewShown(false)
        return endedString
    }

    // MARK: - The field

    func windowWillReturnFieldEditor(_ sender: NSWindow, to client: Any?) -> Any? {
        (client as? NSTextField) === textField ? fieldEditor : nil
    }

    func controlTextDidChange(_ notification: Notification) {
        reportState(isEditingComplete: false)
    }

    /// Return, Enter and Escape end a rename and keep the text, as 15's field did
    /// (`control:textView:doCommandBySelector:`, ecti `0x100000FBC`).
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.cancelOperation(_:)):
            reportState(isEditingComplete: true)
            return true
        default:
            return false
        }
    }

    private func reportState(isEditingComplete: Bool) {
        guard peerListener.isServingPeer else { return }
        let string = fieldEditor.committedString
        let hasMarkedText = fieldEditor.hasMarkedText()
        guard isEditingComplete || string != lastReportedString || hasMarkedText != lastReportedHasMarkedText else { return }
        lastReportedString = string
        lastReportedHasMarkedText = hasMarkedText
        peerListener.send(.fieldChange(TextInputChange(string: string, hasMarkedText: hasMarkedText, isEditingComplete: isEditingComplete)))
    }

    // MARK: - AppKit and text services

    /// The Dock tile's mini view window, shown and at Launchpad's level, 27. 27.2's Dock no longer tells
    /// AppKit the mini view is shown, so this says it; until then the window cannot become key.
    private func showMiniViewWindow() -> NSWindow? {
        if containerView.window == nil {
            NSApp.dockTile.miniView = containerView
            NSApp.dockTile._setMiniViewWindowLevel(27)
        }
        NSApp.dockTile._setMiniViewShown(true)
        guard let window = containerView.window else {
            #log(.error, "The Dock tile made no mini view window")
            return nil
        }
        Self.makeInvisibleOnScreen(window)
        window.delegate = self
        return window
    }

    /// Once the mini view is shown, AppKit leaves its window on screen at the level it was given, 27, though
    /// only the Dock's `CALayerHost` is meant to show the field. What the window draws there is not the
    /// springboard's: a window that came on screen after Launchpad's own sat over it, so the caret stayed
    /// over an open folder instead of fading with the pages, and the last search stayed over other
    /// applications once the springboard had gone. Fully transparent, it shows nothing.
    static func makeInvisibleOnScreen(_ window: NSWindow) {
        window.alphaValue = 0
    }

    /// `window._contextForLayerHosting.contextId`: what a `CALayerHost` in the Dock shows.
    private static func layerHostingContextIdentifier(of window: NSWindow) -> UInt32 {
        guard let context = window._contextForLayerHosting else {
            #log(.error, "The mini view window has no layer-hosting context")
            return 0
        }
        return context.contextId
    }

    /// Text services treat the process as the active one while the remote view is active; the ecti service
    /// turned it on with `_TSMRegisterRemoteViewClient` once it was set up.
    private static func setRemoteViewActivation(_ isActive: Bool) {
        remoteViewActivation?(isActive ? 1 : 0)
        if isActive {
            remoteViewClientRegistration?(1)
        }
    }
}

private typealias RemoteViewActivationFunction = @convention(c) (UInt8) -> Void
private typealias RemoteViewClientRegistrationFunction = @convention(c) (UInt32) -> Void

/// HIToolbox's `_TSMSetRemoteViewActivation` and `_TSMRegisterRemoteViewClient`, which its stub exports
/// without declaring; looked up once.
private nonisolated(unsafe) let remoteViewActivation: RemoteViewActivationFunction? = dlsym(dlopen(nil, RTLD_NOW), "_TSMSetRemoteViewActivation")
    .map { unsafeBitCast($0, to: RemoteViewActivationFunction.self) }
private nonisolated(unsafe) let remoteViewClientRegistration: RemoteViewClientRegistrationFunction? = dlsym(dlopen(nil, RTLD_NOW), "_TSMRegisterRemoteViewClient")
    .map { unsafeBitCast($0, to: RemoteViewClientRegistrationFunction.self) }
