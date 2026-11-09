import CoreGraphics
import Foundation
import ObjCRuntimeToolbox
import LaunchpadAwakenerShared
import ObjectiveC
import OSToolbox
import QuartzCore
import XPC

/// An XPC object handed from libxpc's handler to the main actor; the handlers run on the main queue.
private struct XPCObjectBox: @unchecked Sendable {
    let object: xpc_object_t
}

/// The connection to the text input helper, the LaunchAgent that hosts the springboard's text fields so
/// that input methods work in them, and the events posted to it, as macOS 15's Dock had its
/// `com.apple.dock.ecti` service (`-[ECTextInputLayer _setupConnection]`, `_forwardEvent:`).
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "TextInputHelperClient")
@MainActor
final class TextInputHelperClient {
    /// What showing the hosted field takes, and where its events go.
    struct Hosting: Equatable {
        let contextIdentifier: UInt32
        let processIdentifier: pid_t
        let windowNumber: Int
    }

    /// The field as the helper reports it: the text without what is still composing.
    struct Change: Equatable {
        let string: String
        let hasMarkedText: Bool
        let isEditingComplete: Bool
    }

    private typealias MessageKey = TextInputServiceIdentity.MessageKey
    private typealias Request = TextInputServiceIdentity.Request

    static let shared = TextInputHelperClient()

    /// Called with every change the helper reports.
    var changeHandler: ((Change) -> Void)?
    /// Called when the helper went away; whatever it hosted is gone.
    var interruptionHandler: (() -> Void)?

    private var connection: xpc_connection_t?

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
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, MessageKey.request, Request.begin)
        xpc_dictionary_set_bool(message, MessageKey.isSearchField, isSearchField)
        xpc_dictionary_set_string(message, MessageKey.string, string)
        xpc_dictionary_set_bool(message, MessageKey.selectsAll, selectsAll)
        xpc_dictionary_set_bool(message, MessageKey.hasFocus, hasFocus)
        xpc_dictionary_set_double(message, MessageKey.width, Double(size.width))
        xpc_dictionary_set_double(message, MessageKey.height, Double(size.height))
        xpc_dictionary_set_double(message, MessageKey.fontSize, Double(fontSize))
        xpc_dictionary_set_double(message, MessageKey.screenLeft, Double(screenTopLeft.x))
        xpc_dictionary_set_double(message, MessageKey.screenTop, Double(screenTopLeft.y))
        xpc_connection_send_message_with_reply(currentConnection(), message, DispatchQueue.main) { reply in
            let replyBox = XPCObjectBox(object: reply)
            MainActor.assumeIsolated {
                completion(Self.hosting(from: replyBox.object))
            }
        }
    }

    func setString(_ string: String) {
        guard let connection else { return }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, MessageKey.request, Request.setString)
        xpc_dictionary_set_string(message, MessageKey.string, string)
        xpc_connection_send_message(connection, message)
    }

    func setFocus(_ hasFocus: Bool) {
        guard let connection else { return }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, MessageKey.request, Request.setFocus)
        xpc_dictionary_set_bool(message, MessageKey.hasFocus, hasFocus)
        xpc_connection_send_message(connection, message)
    }

    /// Commits any composing text and lets the field go; `completion` gets the final text, composing text
    /// included, or nil when the helper did not answer.
    func end(completion: @escaping @MainActor (String?) -> Void) {
        guard let connection else {
            completion(nil)
            return
        }
        let message = xpc_dictionary_create(nil, nil, 0)
        xpc_dictionary_set_string(message, MessageKey.request, Request.end)
        xpc_connection_send_message_with_reply(connection, message, DispatchQueue.main) { reply in
            let replyBox = XPCObjectBox(object: reply)
            MainActor.assumeIsolated {
                let reply = replyBox.object
                guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
                    completion(nil)
                    return
                }
                completion(xpc_dictionary_get_string(reply, MessageKey.string).map { String(cString: $0) })
            }
        }
    }

    /// A `CALayerHost` showing the helper's field, once `-[CALayerHost setContextId:]` is the one this
    /// payload knows; nil otherwise.
    static func makeLayerHost(showing hosting: Hosting) -> CALayer? {
        guard let layerHostClass else { return nil }
        let hostLayer = layerHostClass.hostClass.init()
        layerHostClass.setContextIdentifier(hostLayer, layerHostClass.selector, hosting.contextIdentifier)
        return hostLayer
    }

    /// `CALayerHost` and its `-setContextId:`, once the setter's signature is checked, frame offsets
    /// aside; looked up once.
    private struct LayerHostClass {
        typealias SetContextIdentifierFunction = @convention(c) (AnyObject, Selector, UInt32) -> Void
        let hostClass: CALayer.Type
        let selector: Selector
        let setContextIdentifier: SetContextIdentifierFunction
    }

    private static let layerHostClass = findLayerHostClass()

    private static func findLayerHostClass() -> LayerHostClass? {
        let selector = NSSelectorFromString("setContextId:")
        guard
            let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type,
            RuntimeMethodInspector.hasMethod(className: "CALayerHost", selector: selector, matchingTypeEncoding: "v20@0:8I16"),
            let method = class_getInstanceMethod(hostClass, selector)
        else {
            #log(.error, "-[CALayerHost setContextId:] is missing or changed; the fields are edited here")
            return nil
        }
        return LayerHostClass(
            hostClass: hostClass,
            selector: selector,
            setContextIdentifier: unsafeBitCast(method_getImplementation(method), to: LayerHostClass.SetContextIdentifierFunction.self)
        )
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

    // MARK: - The connection

    private func currentConnection() -> xpc_connection_t {
        if let connection {
            return connection
        }
        let newConnection = xpc_connection_create_mach_service(TextInputServiceIdentity.machServiceName, DispatchQueue.main, 0)
        xpc_connection_set_event_handler(newConnection) { event in
            let eventBox = XPCObjectBox(object: event)
            MainActor.assumeIsolated {
                TextInputHelperClient.shared.handle(eventBox.object)
            }
        }
        xpc_connection_resume(newConnection)
        connection = newConnection
        return newConnection
    }

    private func handle(_ event: xpc_object_t) {
        guard xpc_get_type(event) == XPC_TYPE_DICTIONARY else {
            // The helper exited or was never there; launchd starts it again on the next message.
            if xpc_equal(event, XPC_ERROR_CONNECTION_INVALID) {
                #log(.info, "The text input helper is not available")
                connection = nil
            } else {
                #log(.info, "The text input helper went away")
            }
            interruptionHandler?()
            return
        }
        guard
            let requestPointer = xpc_dictionary_get_string(event, MessageKey.request),
            String(cString: requestPointer) == Request.changed
        else { return }
        changeHandler?(Change(
            string: xpc_dictionary_get_string(event, MessageKey.string).map { String(cString: $0) } ?? "",
            hasMarkedText: xpc_dictionary_get_bool(event, MessageKey.hasMarkedText),
            isEditingComplete: xpc_dictionary_get_bool(event, MessageKey.isEditingComplete)
        ))
    }

    private static func hosting(from reply: xpc_object_t) -> Hosting? {
        guard xpc_get_type(reply) == XPC_TYPE_DICTIONARY else {
            #log(.info, "The text input helper did not answer; the field is edited here")
            return nil
        }
        let contextIdentifier = UInt32(truncatingIfNeeded: xpc_dictionary_get_uint64(reply, MessageKey.contextIdentifier))
        guard contextIdentifier != 0 else {
            #log(.error, "The text input helper could not host the field")
            return nil
        }
        return Hosting(
            contextIdentifier: contextIdentifier,
            processIdentifier: pid_t(truncatingIfNeeded: xpc_dictionary_get_int64(reply, MessageKey.processIdentifier)),
            windowNumber: Int(xpc_dictionary_get_int64(reply, MessageKey.windowNumber))
        )
    }

    /// `CGEventSetWindowLocation`, which CoreGraphics exports without declaring.
    private typealias SetWindowLocationFunction = @convention(c) (CGEvent, CGPoint) -> Void
    private static let setWindowLocation: SetWindowLocationFunction? = {
        guard let symbol = dlsym(dlopen(nil, RTLD_NOW), "CGEventSetWindowLocation") else { return nil }
        return unsafeBitCast(symbol, to: SetWindowLocationFunction.self)
    }()
}
