import CoreGraphics
import Foundation
import OSToolbox
import QuartzCore
import LaunchpadAwakenerSpringboardCore

/// A springboard text field hosted by the text input helper, so that input methods work in it: the
/// `CALayerHost` that shows it in the Dock, and the keys and clicks that go to it, as macOS 15's
/// `ECTextInputLayer` had them. Until the helper hosts it, or once the helper goes away, the springboard
/// edits the field itself.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "SpringboardRemoteTextField")
@MainActor
final class SpringboardRemoteTextField {
    typealias Configuration = SpringboardHostedTextFieldConfiguration

    let configuration: Configuration
    /// Called with the layer showing the hosted field once the helper hosts it, and with nil when it goes.
    var hostLayerDidChange: ((CALayer?) -> Void)?
    /// Called with the helper's text, and whether Return, Enter or Escape ended the editing.
    var stringDidChange: ((String, Bool) -> Void)?
    /// What the springboard's own editing holds now, to bring a late-hosted field up to date.
    var currentString: (() -> String)?

    private var hosting: TextInputHelperClient.Hosting?
    /// Asked the helper to host it: from then on the helper has to be told to let it go, answered or not.
    private var hasBegun = false
    private var isEnded = false
    /// Whether the field has the focus; the helper shows no caret without it.
    private var hasFocus = false
    /// The focus the helper was asked to begin with; it is told again only if that changed meanwhile.
    private var hasFocusAtBeginning = false
    /// Whether an input method is composing text in it: every key is the field's then.
    private(set) var isComposing = false
    /// Key codes whose key-down went to the helper; their key-up follows them.
    private var forwardedKeyCodes: Set<Int64> = []

    init(configuration: Configuration) {
        self.configuration = configuration
    }

    var isHosted: Bool {
        hosting != nil
    }

    func begin() {
        let client = TextInputHelperClient.shared
        client.changeHandler = { [weak self] change in
            self?.receive(change)
        }
        client.interruptionHandler = { [weak self] in
            self?.helperDidGoAway()
        }
        hasBegun = true
        hasFocusAtBeginning = hasFocus
        client.begin(
            isSearchField: configuration.isSearchField,
            string: configuration.string,
            selectsAll: configuration.selectsAll,
            hasFocus: hasFocus,
            size: configuration.size,
            fontSize: configuration.fontSize,
            screenTopLeft: configuration.screenTopLeft
        ) { [weak self] hosting in
            self?.didBegin(with: hosting)
        }
    }

    private func didBegin(with newHosting: TextInputHelperClient.Hosting?) {
        guard !isEnded, let newHosting, let hostLayer = TextInputHelperClient.makeLayerHost(showing: newHosting) else { return }
        hosting = newHosting
        hostLayerDidChange?(hostLayer)
        // Typed, or focused, before the helper answered: the hosted field takes over from there.
        if let currentString = currentString?(), currentString != configuration.string {
            TextInputHelperClient.shared.setString(currentString)
        }
        if hasFocus != hasFocusAtBeginning {
            TextInputHelperClient.shared.setFocus(hasFocus)
        }
        #log(.info, "The \(self.configuration.isSearchField ? "search" : "rename", privacy: .public) field is hosted by process \(newHosting.processIdentifier, privacy: .public)")
    }

    /// Commits any composing text and lets the helper's field go — even one the helper has not answered
    /// for yet — and the layer showing it goes too. `finalString` gets the text as the helper ended it,
    /// composing text included, and whether the helper was hosting the field here: a field it never
    /// hosted was edited here, and the helper's text is not what was typed.
    func end(finalString: (@MainActor (_ endedString: String, _ wasHosted: Bool) -> Void)? = nil) {
        guard !isEnded else { return }
        isEnded = true
        let wasHosted = hosting != nil
        if hasBegun {
            TextInputHelperClient.shared.end { endedString in
                if let endedString {
                    finalString?(endedString, wasHosted)
                }
            }
        }
        hosting = nil
        isComposing = false
        hostLayerDidChange?(nil)
    }

    func setString(_ string: String) {
        guard hosting != nil else { return }
        isComposing = false
        TextInputHelperClient.shared.setString(string)
    }

    /// Without the focus the hosted field shows no caret, as 15's did not.
    func setFocus(_ newHasFocus: Bool) {
        guard newHasFocus != hasFocus else { return }
        hasFocus = newHasFocus
        if hosting != nil {
            TextInputHelperClient.shared.setFocus(newHasFocus)
        }
    }

    private func receive(_ change: TextInputHelperClient.Change) {
        guard !isEnded, hosting != nil else { return }
        isComposing = change.hasMarkedText
        stringDidChange?(change.string, change.isEditingComplete)
    }

    private func helperDidGoAway() {
        guard !isEnded, hosting != nil else { return }
        hosting = nil
        isComposing = false
        forwardedKeyCodes.removeAll()
        hostLayerDidChange?(nil)
        #log(.error, "The text input helper went away; the field is edited here")
    }

    // MARK: - Events

    /// Posts the key or modifier event being handled to the helper. A key-up goes only after its key-down
    /// did. Returns whether it went.
    func forwardCurrentKeyEvent() -> Bool {
        guard let hosting, let event = SpringboardCurrentEvent.event else { return false }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        switch event.type {
        case .keyDown:
            forwardedKeyCodes.insert(keyCode)
        case .keyUp:
            guard forwardedKeyCodes.remove(keyCode) != nil else { return false }
        case .flagsChanged:
            break
        default:
            return false
        }
        TextInputHelperClient.shared.post(event, to: hosting)
        return true
    }

    /// Posts the mouse event being handled to the helper, placed in its window as it falls on the field.
    /// Returns whether it went.
    func forwardCurrentMouseEvent() -> Bool {
        guard let hosting, let event = SpringboardCurrentEvent.event else { return false }
        let windowLocation = CGPoint(
            x: event.location.x - configuration.screenTopLeft.x,
            y: event.location.y - configuration.screenTopLeft.y
        )
        TextInputHelperClient.shared.post(event, to: hosting, windowLocation: windowLocation)
        return true
    }
}
