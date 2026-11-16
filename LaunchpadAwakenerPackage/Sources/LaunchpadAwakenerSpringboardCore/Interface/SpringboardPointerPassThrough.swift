/// Lets the pointer through the springboard's window while the Dock handles an event of a gesture that began on
/// the Dock, so that an icon the Dock drags out lands where it would with no springboard up.
///
/// The Dock drags one of its icons inside the handling of a single drag event: `CoreDragStartDragging` follows
/// the pointer until the button comes up and only then returns (27.2 `sub_100105F8C`). Its drop handler is
/// installed on the Dock's whole window-server connection (`-[DockBar installCoreDragEventHandlers]`, window 0),
/// which the springboard's window shares, so a drop on the springboard reaches it and is taken as a drop back
/// into the Dock: with no gap open, `-[DockBar handleDockEventDropInternal:tile:oldPos:context:]` puts the icon
/// back where it was instead of letting it be removed. macOS 15's Dock sent its drag messages to Launchpad
/// instead for as long as Launchpad showed (15.5 `sub_100118D98`, `sub_100119510`); this Dock knows nothing of
/// the springboard, so the window steps aside instead.
///
/// The Dock receives the events of its drag while it is still handling the one that started it, so calls nest:
/// only the outermost switches the window, and it switches back the same window — even if the springboard was
/// hidden, or shown anew, in between.
@MainActor
package final class SpringboardPointerPassThrough {
    private var nestingDepth = 0
    /// The window the outermost call let the pointer through, until it ends.
    private var passingWindow: (any SpringboardWindow)?

    package init() {}

    /// Called before the Dock handles an event. `window` is the springboard's window on screen, nil when there is
    /// none; every call must be balanced by ``end()`` once the Dock is done with the event.
    package func begin(with window: (any SpringboardWindow)?) {
        if nestingDepth == 0, let window {
            window.setPassesPointerEventsThrough(true)
            passingWindow = window
        }
        nestingDepth += 1
    }

    /// Called once the Dock is done with the event ``begin(with:)`` was called for.
    package func end() {
        guard nestingDepth > 0 else { return }
        nestingDepth -= 1
        guard nestingDepth == 0, let passingWindow else { return }
        self.passingWindow = nil
        passingWindow.setPassesPointerEventsThrough(false)
    }
}
