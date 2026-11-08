import AppKit
import Darwin
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
        // Only the Dock shows the field; anything else could read what is typed.
        guard Self.isDock(processIdentifier: processIdentifier) else {
            #log(.error, "Refused a connection from process \(processIdentifier, privacy: .public), which is not the Dock")
            xpc_connection_cancel(connection)
            return
        }
        if let peer {
            xpc_connection_cancel(peer)
        }
        peer = connection
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
        guard connection === peer else { return }
        guard xpc_get_type(message) == XPC_TYPE_DICTIONARY else {
            // The Dock went away: keep nothing composing and let the field go.
            #log(.info, "The Dock's connection ended")
            peer = nil
            end()
            return
        }
        guard let requestPointer = xpc_dictionary_get_string(message, MessageKey.request) else { return }
        switch String(cString: requestPointer) {
        case Request.begin:
            begin(with: message)
        case Request.setString:
            setString(xpc_dictionary_get_string(message, MessageKey.string).map { String(cString: $0) } ?? "")
        case Request.end:
            end()
        default:
            break
        }
    }

    // MARK: - Requests

    private func begin(with message: xpc_object_t) {
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
        if xpc_dictionary_get_bool(message, MessageKey.selectsAll) {
            textField.selectText(nil)
        } else {
            fieldEditor.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        }
        Self.setRemoteViewActivation(true)
        reply(to: message, contextIdentifier: Self.layerHostingContextIdentifier(of: window), windowNumber: window.windowNumber)
        #log(.info, "Hosting the \(self.isSearchField ? "search" : "rename", privacy: .public) field, \(width, privacy: .public)×\(height, privacy: .public)")
    }

    private func reply(to message: xpc_object_t, contextIdentifier: UInt32, windowNumber: Int) {
        guard let peer, let reply = xpc_dictionary_create_reply(message) else { return }
        xpc_dictionary_set_uint64(reply, MessageKey.contextIdentifier, UInt64(contextIdentifier))
        xpc_dictionary_set_int64(reply, MessageKey.processIdentifier, Int64(ProcessInfo.processInfo.processIdentifier))
        xpc_dictionary_set_int64(reply, MessageKey.windowNumber, Int64(windowNumber))
        xpc_connection_send_message(peer, reply)
    }

    private func setString(_ string: String) {
        fieldEditor.inputContext?.discardMarkedText()
        textField.stringValue = string
        fieldEditor.setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
        lastReportedString = string
        lastReportedHasMarkedText = false
    }

    /// Composing text is kept, as clicking away from any text field keeps it; the final text goes back first.
    private func end() {
        if fieldEditor.hasMarkedText() {
            fieldEditor.unmarkText()
        }
        reportState(isEditingComplete: false)
        Self.setRemoteViewActivation(false)
        Self.callMiniViewMethod("_setMiniViewShown:", typeEncoding: "v20@0:8B16", bool: false)
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
        if containerView.window == nil {
            NSApp.dockTile.setValue(containerView, forKey: "miniView")
            Self.callMiniViewMethod("_setMiniViewWindowLevel:", typeEncoding: "v24@0:8q16", integer: 27)
        }
        Self.callMiniViewMethod("_setMiniViewShown:", typeEncoding: "v20@0:8B16", bool: true)
        guard let window = containerView.window else {
            #log(.error, "The Dock tile made no mini view window")
            return nil
        }
        window.delegate = self
        return window
    }

    private static func callMiniViewMethod(_ selectorName: String, typeEncoding: String, integer: Int) {
        guard let implementation = implementation(of: selectorName, on: NSApp.dockTile, typeEncoding: typeEncoding) else { return }
        typealias IntegerFunction = @convention(c) (AnyObject, Selector, Int) -> Void
        unsafeBitCast(implementation, to: IntegerFunction.self)(NSApp.dockTile, NSSelectorFromString(selectorName), integer)
    }

    private static func callMiniViewMethod(_ selectorName: String, typeEncoding: String, bool: Bool) {
        guard let implementation = implementation(of: selectorName, on: NSApp.dockTile, typeEncoding: typeEncoding) else { return }
        typealias BoolFunction = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(implementation, to: BoolFunction.self)(NSApp.dockTile, NSSelectorFromString(selectorName), bool)
    }

    /// The method's implementation once its type encoding is the expected one; nil and a log otherwise.
    private static func implementation(of selectorName: String, on receiver: AnyObject, typeEncoding expectedTypeEncoding: String) -> IMP? {
        guard
            let method = class_getInstanceMethod(object_getClass(receiver), NSSelectorFromString(selectorName)),
            let typeEncoding = method_getTypeEncoding(method)
        else {
            #log(.error, "No -\(selectorName, privacy: .public) on \(String(describing: type(of: receiver)), privacy: .public)")
            return nil
        }
        guard String(cString: typeEncoding) == expectedTypeEncoding else {
            #log(.error, "-\(selectorName, privacy: .public) is \(String(cString: typeEncoding), privacy: .public), not \(expectedTypeEncoding, privacy: .public)")
            return nil
        }
        return method_getImplementation(method)
    }

    /// `window._contextForLayerHosting.contextId`: what a `CALayerHost` in the Dock shows.
    private static func layerHostingContextIdentifier(of window: NSWindow) -> UInt32 {
        guard
            implementation(of: "_contextForLayerHosting", on: window, typeEncoding: "@16@0:8") != nil,
            let context = window.value(forKey: "_contextForLayerHosting") as? NSObject,
            let contextIdentifier = context.value(forKey: "contextId") as? NSNumber
        else {
            #log(.error, "The mini view window has no layer-hosting context")
            return 0
        }
        return contextIdentifier.uint32Value
    }

    /// Text services treat the process as the active one while the remote view is active; the ecti service
    /// turned it on with `_TSMRegisterRemoteViewClient` once it was set up.
    private static func setRemoteViewActivation(_ isActive: Bool) {
        typealias ActivationFunction = @convention(c) (UInt8) -> Void
        typealias RegistrationFunction = @convention(c) (UInt32) -> Void
        let processHandle = dlopen(nil, RTLD_NOW)
        if let symbol = dlsym(processHandle, "_TSMSetRemoteViewActivation") {
            unsafeBitCast(symbol, to: ActivationFunction.self)(isActive ? 1 : 0)
        }
        if isActive, let symbol = dlsym(processHandle, "_TSMRegisterRemoteViewClient") {
            unsafeBitCast(symbol, to: RegistrationFunction.self)(1)
        }
    }
}
