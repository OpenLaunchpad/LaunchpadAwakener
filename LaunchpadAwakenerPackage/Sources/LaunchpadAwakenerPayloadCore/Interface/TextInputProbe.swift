#if DEBUG
import CoreGraphics
import Foundation
import OSToolbox
import QuartzCore

/// Throwaway probe for the input method proposal (step 1); lives only on experiment/input-method-probe.
///
/// When `LaunchpadAwakenerTextInputProbe` has written /tmp/claude-textinput-probe.json, the springboard
/// shows that process's text field over the search field through a `CALayerHost`, and sends it the key
/// events the Dock receives instead of handling them, Escape aside.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "TextInputProbe")
@MainActor
enum TextInputProbe {
    private struct Peer: Decodable {
        let pid: Int32
        let contextId: UInt32
        let windowNumber: Int
    }

    // Only touched on the main thread; the event hook checks before calling.
    private nonisolated(unsafe) static var peer: Peer?
    private static var hostLayer: CALayer?

    static func attach(to springboardLayer: CALayer, fieldFrame: CGRect) {
        guard
            let data = FileManager.default.contents(atPath: "/tmp/claude-textinput-probe.json"),
            let decodedPeer = try? JSONDecoder().decode(Peer.self, from: data)
        else { return }
        guard let hostClass = NSClassFromString("CALayerHost") as? CALayer.Type else {
            #log(.error, "No CALayerHost class")
            return
        }
        let newHostLayer = hostClass.init()
        newHostLayer.setValue(NSNumber(value: decodedPeer.contextId), forKey: "contextId")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        newHostLayer.frame = fieldFrame
        springboardLayer.addSublayer(newHostLayer)
        CATransaction.commit()
        peer = decodedPeer
        hostLayer = newHostLayer
        #log(.info, "Hosting context \(decodedPeer.contextId, privacy: .public) of process \(decodedPeer.pid, privacy: .public) at \(String(describing: fieldFrame), privacy: .public)")
    }

    static func detach() {
        hostLayer?.removeFromSuperlayer()
        hostLayer = nil
        peer = nil
    }

    /// Sends a key event to the probe's process; returns whether it went there instead of the springboard.
    nonisolated static func forwardKeyEvent(_ event: CGEvent) -> Bool {
        guard let peer else { return false }
        switch event.type {
        case .keyDown, .keyUp:
            guard event.getIntegerValueField(.keyboardEventKeycode) != SpringboardKeyCode.escape else { return false }
        case .flagsChanged:
            break
        default:
            return false
        }
        guard let copiedEvent = event.copy(), let windowField = CGEventField(rawValue: 51) else { return false }
        // 15's Dock marked forwarded events with the service's window (`-[ECTextInputLayer _forwardEvent:]`).
        copiedEvent.setIntegerValueField(windowField, value: Int64(peer.windowNumber))
        copiedEvent.postToPid(peer.pid)
        #log(.info, "Forwarded key event \(event.type.rawValue, privacy: .public) code \(event.getIntegerValueField(.keyboardEventKeycode), privacy: .public) to \(peer.pid, privacy: .public)")
        return true
    }
}
#endif
