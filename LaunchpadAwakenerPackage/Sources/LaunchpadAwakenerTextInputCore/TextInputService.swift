import AppKit
import Darwin
import ObjCRuntimeToolbox
import LaunchpadAwakenerShared
import ObjectiveC
import OSToolbox
import XPC

/// An XPC object handed from libxpc's handler to the main actor; the handlers run on the main queue.
private struct XPCObjectBox: @unchecked Sendable {
    let object: xpc_object_t
}

/// Listens on the helper's Mach service and hosts the one field the payload asks for — the springboard's
/// search field or an open folder's name, which are never edited at once — following macOS 15's
/// `-[ECTIHelperDelegate _handleSetupMessage:forPeer:]` and `_handleSetupMiniViewMessage:forPeer:`.
///
/// The field lives in the Dock tile's mini view window, which never goes on screen but can be key. The
/// payload shows that window's layer-hosting context in the Dock and posts the Dock's keys and clicks to
/// this process; this service reports the text back.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "TextInputService")
@MainActor
final class TextInputService: NSObject, NSTextFieldDelegate, NSWindowDelegate {
    static let shared = TextInputService()

    private typealias MessageKey = TextInputServiceIdentity.MessageKey
    private typealias Request = TextInputServiceIdentity.Request

    private var listener: xpc_connection_t?
    /// The Dock's connection; a new one replaces it when the Dock restarts.
    private var peer: xpc_connection_t?
    private let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
    private let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 200, height: 25))
    private let fieldEditor = TextInputFieldEditor()
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

        let listener = xpc_connection_create_mach_service(
            TextInputServiceIdentity.machServiceName,
            DispatchQueue.main,
            UInt64(XPC_CONNECTION_MACH_SERVICE_LISTENER)
        )
        xpc_connection_set_event_handler(listener) { event in
            let box = XPCObjectBox(object: event)
            MainActor.assumeIsolated {
                TextInputService.shared.accept(box.object)
            }
        }
        xpc_connection_resume(listener)
        self.listener = listener
        #log(.info, "Listening on \(TextInputServiceIdentity.machServiceName, privacy: .public)")
    }

    // MARK: - Connections

    private func accept(_ event: xpc_object_t) {
        guard xpc_get_type(event) == XPC_TYPE_CONNECTION else { return }
        let connection = event as xpc_connection_t
        let processIdentifier = xpc_connection_get_pid(connection)
        // Only the Dock shows the field; anything else could read what is typed. libxpc enforces the
        // Dock's signature on every message; the path is only a quick first look.
        guard
            Self.isDock(processIdentifier: processIdentifier),
            xpc_connection_set_peer_code_signing_requirement(connection, TextInputServiceIdentity.peerCodeSigningRequirement) == 0
        else {
            #log(.error, "Refused a connection from process \(processIdentifier, privacy: .public), which is not the Dock")
            xpc_connection_cancel(connection)
            return
        }
        let connectionBox = XPCObjectBox(object: connection)
        xpc_connection_set_event_handler(connection) { message in
            let messageBox = XPCObjectBox(object: message)
            MainActor.assumeIsolated {
                TextInputService.shared.handle(messageBox.object, from: connectionBox.object)
            }
        }
        xpc_connection_set_target_queue(connection, DispatchQueue.main)
        xpc_connection_resume(connection)
        #log(.info, "The Dock connected (process \(processIdentifier, privacy: .public))")
    }

    private static func isDock(processIdentifier: pid_t) -> Bool {
        var pathBuffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(processIdentifier, &pathBuffer, UInt32(pathBuffer.count)) > 0 else { return false }
        return String(cString: pathBuffer) == "/System/Library/CoreServices/Dock.app/Contents/MacOS/Dock"
    }

    private func handle(_ message: xpc_object_t, from connection: xpc_object_t) {
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
            // The Dock went away: keep nothing composing and let the field go. Another connection failing
            // its signature check changes nothing, but leaves the fields without input methods.
            guard connection === peer else {
                if message === XPC_ERROR_PEER_CODE_SIGNING_REQUIREMENT {
                    #log(.error, "Refused process \(xpc_connection_get_pid(connection), privacy: .public)'s messages: it is not the Apple-signed Dock")
                }
                return
            }
            #log(.info, "The Dock's connection ended")
            peer = nil
            end()
            return
        }
        // A message that passed the signature check: this is the Dock, a restarted one replacing the last.
        if connection !== peer {
            if let peer {
                xpc_connection_cancel(peer)
            }
            peer = connection
        }
        guard let requestPointer = xpc_dictionary_get_string(message, MessageKey.request) else { return }
        switch String(cString: requestPointer) {
        case Request.begin:
            begin(with: message)
        case Request.setString:
            setString(xpc_dictionary_get_string(message, MessageKey.string).map { String(cString: $0) } ?? "")
        case Request.setFocus:
            showCaret(xpc_dictionary_get_bool(message, MessageKey.hasFocus))
        case Request.end:
            let endedString = end()
            // The final text, composing text included, for a rename that ended while text was composing;
            // none when this field was never set up, as the text left is then another field's.
            if let peer, let reply = xpc_dictionary_create_reply(message) {
                if let endedString {
                    xpc_dictionary_set_string(reply, MessageKey.string, endedString)
                }
                xpc_connection_send_message(peer, reply)
            }
        default:
            break
        }
    }

    // MARK: - Requests

    private func begin(with message: xpc_object_t) {
        isHosting = false
        // A deployment replaced this executable: the new one hosts the field from the next opening on.
        guard Self.currentExecutableIdentity() == executableIdentity else {
            #log(.info, "A new build replaced the helper; exiting so that launchd starts that one")
            reply(to: message, contextIdentifier: 0, windowNumber: 0)
            DispatchQueue.main.async {
                exit(EXIT_SUCCESS)
            }
            return
        }
        // A field editor keeps what it was set up with — the search field's alignment, say — so the new
        // field starts its editing afresh.
        containerView.window?.makeFirstResponder(nil)
        isSearchField = xpc_dictionary_get_bool(message, MessageKey.isSearchField)
        let string = xpc_dictionary_get_string(message, MessageKey.string).map { String(cString: $0) } ?? ""
        let width = xpc_dictionary_get_double(message, MessageKey.width)
        let height = xpc_dictionary_get_double(message, MessageKey.height)
        let fontSize = xpc_dictionary_get_double(message, MessageKey.fontSize)
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
            reply(to: message, contextIdentifier: 0, windowNumber: 0)
            return
        }
        // Candidate windows are placed from where the window is on screen: where the field is shown.
        let screenLeft = xpc_dictionary_get_double(message, MessageKey.screenLeft)
        let screenTop = xpc_dictionary_get_double(message, MessageKey.screenTop)
        let zeroScreenHeight = NSScreen.screens.first?.frame.height ?? 0
        window.setFrame(NSRect(x: screenLeft, y: zeroScreenHeight - screenTop - height, width: width, height: height), display: false)
        window.makeKey()
        window.makeFirstResponder(textField)
        fieldEditor.alignment = textField.alignment
        if xpc_dictionary_get_bool(message, MessageKey.selectsAll) {
            textField.selectText(nil)
        } else {
            fieldEditor.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        }
        showCaret(xpc_dictionary_get_bool(message, MessageKey.hasFocus))
        Self.setRemoteViewActivation(true)
        let contextIdentifier = Self.layerHostingContextIdentifier(of: window)
        isHosting = contextIdentifier != 0
        reply(to: message, contextIdentifier: contextIdentifier, windowNumber: window.windowNumber)
        #log(.info, "Hosting the \(self.isSearchField ? "search" : "rename", privacy: .public) field, \(width, privacy: .public)×\(height, privacy: .public)")
    }

    private func reply(to message: xpc_object_t, contextIdentifier: UInt32, windowNumber: Int) {
        guard let peer, let reply = xpc_dictionary_create_reply(message) else { return }
        xpc_dictionary_set_uint64(reply, MessageKey.contextIdentifier, UInt64(contextIdentifier))
        xpc_dictionary_set_int64(reply, MessageKey.processIdentifier, Int64(ProcessInfo.processInfo.processIdentifier))
        xpc_dictionary_set_int64(reply, MessageKey.windowNumber, Int64(windowNumber))
        xpc_connection_send_message(peer, reply)
    }

    /// Without the focus the field shows no caret, as 15's did not. It stays the first responder, so that
    /// the next key forwarded to it still lands.
    private func showCaret(_ hasFocus: Bool) {
        fieldEditor.insertionPointColor = hasFocus ? .white : .clear
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
        AppKitDockTileMiniViewImplementation(NSApp.dockTile)?._setMiniViewShown(false)
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
        guard let peer else { return }
        let string = fieldEditor.committedString
        let hasMarkedText = fieldEditor.hasMarkedText()
        guard isEditingComplete || string != lastReportedString || hasMarkedText != lastReportedHasMarkedText else { return }
        lastReportedString = string
        lastReportedHasMarkedText = hasMarkedText
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, MessageKey.request, Request.changed)
        xpc_dictionary_set_string(message, MessageKey.string, string)
        xpc_dictionary_set_bool(message, MessageKey.hasMarkedText, hasMarkedText)
        xpc_dictionary_set_bool(message, MessageKey.isEditingComplete, isEditingComplete)
        xpc_connection_send_message(peer, message)
    }

    // MARK: - AppKit and text services

    /// The Dock tile's mini view window, shown and at Launchpad's level, 27. 27.2's Dock no longer tells
    /// AppKit the mini view is shown, so this says it; until then the window cannot become key.
    private func showMiniViewWindow() -> NSWindow? {
        let miniView = AppKitDockTileMiniViewImplementation(NSApp.dockTile)
        if miniView == nil {
            #log(.error, "NSDockTile's mini view methods are missing or changed")
        }
        if containerView.window == nil {
            NSApp.dockTile.setValue(containerView, forKey: "miniView")
            miniView?._setMiniViewWindowLevel(27)
        }
        miniView?._setMiniViewShown(true)
        guard let window = containerView.window else {
            #log(.error, "The Dock tile made no mini view window")
            return nil
        }
        window.delegate = self
        return window
    }

    /// `window._contextForLayerHosting.contextId`: what a `CALayerHost` in the Dock shows.
    ///
    /// `contextId` is read without a check of its own: it takes nothing, `DynamicObject` reads the result
    /// by its real signature, and `asUInt32` yields nil unless that result is four bytes.
    private static func layerHostingContextIdentifier(of window: NSWindow) -> UInt32 {
        guard
            hasMethod(window, "_contextForLayerHosting", typeEncoding: "@16@0:8"),
            let context = ObjC(window)._contextForLayerHosting.asObject,
            let contextIdentifier = ObjC(context).contextId.asUInt32
        else {
            #log(.error, "The mini view window has no layer-hosting context")
            return 0
        }
        return contextIdentifier
    }

    /// Whether `receiver`'s own class has `selectorName` with `expectedTypeEncoding`, frame offsets aside;
    /// logs what it found when not.
    private static func hasMethod(_ receiver: AnyObject, _ selectorName: String, typeEncoding expectedTypeEncoding: String) -> Bool {
        guard
            let receiverClass = object_getClass(receiver),
            let typeEncoding = RuntimeMethodInspector.typeEncoding(forClass: receiverClass, selector: NSSelectorFromString(selectorName))
        else {
            #log(.error, "No -\(selectorName, privacy: .public) on \(String(describing: type(of: receiver)), privacy: .public)")
            return false
        }
        guard ObjCTypeEncodingNormalization.matches(typeEncoding, expectedTypeEncoding) else {
            #log(.error, "-\(selectorName, privacy: .public) is \(typeEncoding, privacy: .public), not \(expectedTypeEncoding, privacy: .public)")
            return false
        }
        return true
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

/// The mini view methods of `NSDockTile` that 27.2's Dock no longer calls for an application, declared on
/// `NSDockTile` itself.
@RuntimeClassProxy("NSDockTile")
protocol AppKitDockTileMiniView {
    /// The window level of the tile's mini view window.
    func _setMiniViewWindowLevel(_ windowLevel: Int)
    /// Until this is said, the mini view window cannot become key.
    func _setMiniViewShown(_ isShown: Bool)
}
