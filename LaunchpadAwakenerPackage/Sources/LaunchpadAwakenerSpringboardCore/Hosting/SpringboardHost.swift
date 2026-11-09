import CoreGraphics
import Foundation
import os
import QuartzCore

// MARK: - The host

/// What the springboard needs from the process it is drawn in: the Dock, which the payload is injected
/// into, or the standalone app.
///
/// Each process has exactly one, chosen once by ``SpringboardHostSystem/bootstrap(host:)`` before the
/// springboard first shows — the way swift-log's `LoggingSystem.bootstrap` chooses a backend. The
/// requirements read off the main actor are `nonisolated`: Core Animation copies item layers on its own
/// threads, and the layout library is set up before the main actor ever runs springboard code.
@MainActor
package protocol SpringboardHost: AnyObject, Sendable {
    /// The Dock's own `EC*` layer classes, or stand-ins drawn the same way.
    nonisolated var layerFactory: any SpringboardLayerFactory { get }
    /// Where macOS 15's `springboard-*` keys are read: the Dock's own defaults inside the Dock,
    /// `com.apple.dock` elsewhere.
    nonisolated var preferences: UserDefaults { get }
    /// Where the layout library keeps its database and what it imports on its first start.
    nonisolated var libraryConfiguration: LaunchpadLibrary.Configuration { get }
    /// The bundle macOS 15's own resources come from — the Dock's, where Launchpad lived: the search
    /// field's and the close box's images, the languages the springboard speaks, and words such as
    /// "Untitled". Nil leaves the images out and the words in English.
    nonisolated var resourceBundle: Bundle? { get }

    /// The room the Dock takes at the edge of the screen, and the camera housing at the top.
    var dockGeometry: SpringboardDockGeometry { get }
    /// The style application icons are drawn in; nil draws the default style.
    var iconStyle: SpringboardIconStyle? { get }
    /// Deletes applications; nil keeps close boxes out of jiggle mode.
    var applicationUninstaller: (any SpringboardApplicationUninstaller)? { get }

    /// A full-screen window above every application window, not yet on screen; nil when none can be made.
    func makeWindow(onDisplay displayIdentifier: CGDirectDisplayID) -> (any SpringboardWindow)?
    /// The wallpaper as it is now, for macOS 15's blurred background; nil leaves 15's gradient.
    func wallpaperImage(onDisplay displayIdentifier: CGDirectDisplayID) -> CGImage?
    /// Whether `springboard-background` set to `glass` means anything here. Where it does not, the
    /// springboard keeps 15's blurred wallpaper rather than a stand-in blur of whatever is behind it.
    var offersGlassBackground: Bool { get }
    /// The glass behind the pages when `springboard-background` is `glass`; nil leaves the stand-in blur.
    func makeGlassBackground(frame: CGRect, scale: CGFloat, backdropGroupName: String) -> (any SpringboardGlassBackground)?
    /// A text field another process hosts so that input methods work in it; nil edits the field in place.
    func makeHostedTextField(configuration: SpringboardHostedTextFieldConfiguration) -> (any SpringboardHostedTextField)?
    /// The system's input methods for the fields edited in place, where the host's window takes the
    /// keyboard itself; nil where they are out of reach, as in the Dock.
    var inputMethod: (any SpringboardInputMethod)? { get }
    /// Whether a click at `globalPoint` — top-left origin, as `CGEvent.location` — belongs to a Dock drawn
    /// above the springboard.
    func isOnDock(_ globalPoint: CGPoint) -> Bool
    /// Keeps the Dock on screen or slides it away, as macOS 15 did while the springboard showed. Called
    /// with the whole state wanted, again whenever it may have changed; a host asks the Dock only for what
    /// changed. Does nothing where the Dock is out of reach or covered by the springboard's window.
    func setDockVisibility(_ visibility: SpringboardDockVisibility)
}

/// The host this process chose.
package enum SpringboardHostSystem {
    private static let chosenHost = OSAllocatedUnfairLock<(any SpringboardHost)?>(initialState: nil)
    private static let detachedHost = DetachedSpringboardHost()

    /// Chooses this process's host. Call once, before the springboard first shows; a second call traps.
    package static func bootstrap(host: some SpringboardHost) {
        chosenHost.withLock { currentHost in
            precondition(currentHost == nil, "The springboard's host can only be chosen once")
            currentHost = host
        }
    }

    /// The chosen host; until one is chosen — in unit tests, for one — a host with no window, no
    /// wallpaper and no hosted fields.
    package static var host: any SpringboardHost {
        chosenHost.withLock { $0 } ?? detachedHost
    }

    package static var layerFactory: any SpringboardLayerFactory {
        host.layerFactory
    }

    package static var preferences: UserDefaults {
        host.preferences
    }
}

// MARK: - What the host provides

/// The Dock's `EC*` layer classes as the springboard uses them, or layers drawn the same way.
///
/// Grids are plain `CALayer`s to their callers, who size and place them; only the factory that made a
/// grid lays it out, fills it or scrolls it.
package protocol SpringboardLayerFactory: Sendable {
    /// One page, its cells sized from its bounds and filled from the top left, row by row
    /// (`ECGridLayer`). It asks `source` for the item count once, now, and holds `source` weakly.
    func makePageGridLayer(source: SpringboardGridSource, rowCount: Int, columnCount: Int, scaleFactor: Float) -> CALayer?
    /// Lays out and fills a page grid's items; Core Animation never does it by itself.
    func layoutPageGridLayer(_ gridLayer: CALayer)

    /// A folder icon's thumbnails (`ECImageGridLayer`), holding `source` weakly.
    func makeThumbnailGridLayer(source: SpringboardThumbnailSource, rowCount: Int, columnCount: Int, spacing: UInt, scaleFactor: Float) -> CALayer?
    func layoutThumbnailGridLayer(_ gridLayer: CALayer)
    /// Asks `source` for the item count and every item again, then lays out.
    func invalidateThumbnailGridLayer(_ gridLayer: CALayer, source: SpringboardThumbnailSource)
    /// Shows the slot after the last item, as while an icon is held over the folder, or scrolls back to
    /// the top; animated if the current transaction animates.
    func scrollThumbnailGridLayer(_ gridLayer: CALayer, toAvailableSpace: Bool)

    /// A text layer; with a shadow, the shadow is drawn with the text rather than as a layer shadow
    /// (`ECShadowTextLayer`).
    func makeTextLayer(withShadow: Bool) -> CATextLayer
    /// The shadow of a text layer made with one, in points.
    func setTextShadow(of textLayer: CATextLayer, color: CGColor, offset: CGSize, blur: CGFloat)
    /// macOS 15's selection highlight: grey 232/255 that darkens whatever lies behind it
    /// (`-[CALayer setMaterialControl:3 appearance:1]`).
    func applySelectionMaterial(to layer: CALayer)
}

/// The window the springboard is drawn in.
@MainActor
package protocol SpringboardWindow: AnyObject {
    /// Global coordinates with a top-left origin.
    var displayBounds: CGRect { get }
    var backingScaleFactor: CGFloat { get }
    var rootLayer: CALayer { get }
    var isOrderedIn: Bool { get }

    /// Converts a global point (top-left origin) into the window's coordinates.
    func windowPoint(fromGlobalPoint globalPoint: CGPoint) -> CGPoint
    /// Puts the window on screen above everything and takes the keyboard.
    func orderIn()
    /// Gives the keyboard back without closing, as 15 did the moment its exit animation started.
    /// `returningToPreviousApplication` is false when an application was just opened from the springboard:
    /// that application takes the keyboard itself, so a host that made itself the active application must
    /// not hand it to the one that was active before.
    func releaseKeyFocus(returningToPreviousApplication: Bool)
    func orderOut()
}

/// Where the Dock sits and how much room 15's layout leaves it.
package struct SpringboardDockGeometry: Sendable, Equatable {
    package var orientation: DockOrientation
    /// The room left for the Dock, in points: 79 at the default size.
    package var thickness: CGFloat
    /// The camera housing's height on the display; zero without one.
    package var notchHeight: CGFloat

    package init(orientation: DockOrientation, thickness: CGFloat, notchHeight: CGFloat) {
        self.orientation = orientation
        self.thickness = thickness
        self.notchHeight = notchHeight
    }

    /// A Dock at the bottom at its default size, on a display without a camera housing.
    package static let standard = SpringboardDockGeometry(orientation: .bottom, thickness: SpringboardMetrics.defaultDockThickness, notchHeight: 0)
}

/// Where macOS 15 wanted the Dock while the springboard showed.
///
/// Opening the springboard kept the Dock on screen, even a Dock set to hide itself
/// (`-[LPSpringboard setVisible:slow:forGaming:reason:]`, 15.5 `0x1000B0434`, set the Dock's show override).
/// An open folder slid it away, from the moment the panel started to open to the moment it started to
/// close (`-[Springboard groupShownForItem:atIndex:]` `0x100093500` and `groupHiddenForItem:`
/// `0x1000935A4`): a five-row folder's panel reaches down to where the Dock was. As the springboard started
/// to go, the Dock came back with the exit animation (`0x10009173C`), and the override was let go once that
/// animation had ended (`0x1000B079C`).
package enum SpringboardDockVisibility: Sendable, Equatable {
    /// As the user set it up: the springboard is away.
    case unchanged
    /// On screen, even if set to hide itself: the springboard shows its pages, or is going.
    case keptVisible
    /// Slid away: a folder is open.
    case hidden

    /// - Parameters:
    ///   - isShowing: The springboard is on screen and taking input.
    ///   - isHiding: The springboard's exit animation is playing.
    ///   - isFolderOpen: The showing springboard has a folder open that is not closing.
    package init(isShowing: Bool, isHiding: Bool, isFolderOpen: Bool) {
        if isShowing {
            self = isFolderOpen ? .hidden : .keptVisible
        } else {
            self = isHiding ? .keptVisible : .unchanged
        }
    }
}

/// The icon style the Dock draws its own tiles in (`IconAppearance`).
package struct SpringboardIconStyle {
    /// An `ISImageDescriptor` set up for the style; copied, never changed, for every icon.
    package let iconDescriptor: NSObject
    /// `IconStyle`: 0 and 1 default, 2 and 3 clear, 4 and 5 tinted — light and dark each.
    package let style: UInt8

    package init(iconDescriptor: NSObject, style: UInt8) {
        self.iconDescriptor = iconDescriptor
        self.style = style
    }

    /// The compositing filter the Dock gives its tile images in this style
    /// (`IconStyle_GlassCompositingFilter`, 27.2 `0x10016AC54`).
    package var glassCompositingFilterName: String? {
        switch style {
        case 2, 3, 4: QuartzCorePrivate.stringConstant(named: "kCAFilterClearIconBlendMode")
        case 5: QuartzCorePrivate.stringConstant(named: "kCAFilterScreenBlendMode")
        default: nil
        }
    }
}

/// Deletes applications from jiggle mode, as 15's Launchpad did with the Dock's uninstaller.
@MainActor
package protocol SpringboardApplicationUninstaller: AnyObject {
    /// Whether the application gets a close box.
    func canUninstall(applicationAt bundleURL: URL) -> Bool
    /// Deletes the application; `completion` runs on the main actor with whether it went.
    func uninstall(applicationAt bundleURL: URL, completion: @escaping @MainActor @Sendable (Bool) -> Void)
}

/// A glass behind the pages, kept alive for as long as it shows.
@MainActor
package protocol SpringboardGlassBackground: AnyObject {
    var rootLayer: CALayer { get }
}

/// What a hosted text field starts with.
package struct SpringboardHostedTextFieldConfiguration: Sendable {
    package let isSearchField: Bool
    package let string: String
    package let selectsAll: Bool
    /// The text area's size, which the hosted field fills.
    package let size: CGSize
    package let fontSize: CGFloat
    /// The text area's top-left corner on screen, from the top left of the main display.
    package let screenTopLeft: CGPoint

    package init(isSearchField: Bool, string: String, selectsAll: Bool, size: CGSize, fontSize: CGFloat, screenTopLeft: CGPoint) {
        self.isSearchField = isSearchField
        self.string = string
        self.selectsAll = selectsAll
        self.size = size
        self.fontSize = fontSize
        self.screenTopLeft = screenTopLeft
    }
}

/// A springboard text field another process hosts so that input methods work in it, shown in the
/// springboard through a layer. Until it is hosted, and once it no longer is, the springboard edits the
/// field itself.
@MainActor
package protocol SpringboardHostedTextField: AnyObject {
    var configuration: SpringboardHostedTextFieldConfiguration { get }
    /// Called with the layer showing the hosted field once it is hosted, and with nil when it goes.
    var hostLayerDidChange: ((CALayer?) -> Void)? { get set }
    /// Called with the hosted field's text, and whether Return, Enter or Escape ended the editing.
    var stringDidChange: ((String, Bool) -> Void)? { get set }
    /// What the springboard's own editing holds now, to bring a late-hosted field up to date.
    var currentString: (() -> String)? { get set }
    var isHosted: Bool { get }
    /// Whether an input method is composing text in it: every key is the field's then.
    var isComposing: Bool { get }

    func begin()
    /// Commits any composing text and lets the hosted field go. `finalString` gets the text as the field
    /// ended, and whether it was hosted here when it ended.
    func end(finalString: (@MainActor (_ endedString: String, _ wasHosted: Bool) -> Void)?)
    func setString(_ string: String)
    /// Without the focus the hosted field shows no caret, as 15's did not.
    func setFocus(_ newHasFocus: Bool)
    /// Hands it the key or modifier event being handled; returns whether it went.
    func forwardCurrentKeyEvent() -> Bool
    /// Hands it the mouse event being handled, placed as it falls on the field; returns whether it went.
    func forwardCurrentMouseEvent() -> Bool
}

extension SpringboardHostedTextField {
    /// Lets the hosted field go without asking for its final text.
    func end() {
        end(finalString: nil)
    }
}

/// The system's input methods, for a host whose own window takes the keyboard: the springboard offers
/// them the keys that would type into a field, and every key while they compose.
@MainActor
package protocol SpringboardInputMethod: AnyObject {
    /// The showing springboard, whose field the input methods type into.
    var client: (any SpringboardInputMethodClient)? { get set }
    /// Offers the key or modifier event being handled to the input methods; returns whether they took it.
    /// A key they turn into a command, such as moving the caret, is not taken: it stays the springboard's.
    func handleCurrentEvent() -> Bool
    /// Tells the input methods that what they were composing was taken as typed, by a click elsewhere or
    /// the field going away, so that they start afresh.
    func discardComposition()
}

/// The springboard's side of the input methods: the field taking text — the folder's name while it is
/// renamed, the search field otherwise. Ranges count UTF-16 units of the field's text as shown, with what
/// is being composed in place of the selection, as AppKit's text input does.
@MainActor
package protocol SpringboardInputMethodClient: AnyObject {
    /// The field's text as shown; nil while no field takes text.
    var inputMethodText: String? { get }
    var inputMethodSelectedRange: NSRange { get }
    /// What is being composed; nil while nothing is.
    var inputMethodMarkedRange: NSRange? { get }
    /// Typed or committed text, in place of the selection or the composed text.
    func inputMethodInsert(_ text: String)
    func inputMethodSetMarkedText(_ text: String, selectedUTF16Range: NSRange)
    /// Takes what was being composed as typed (`unmarkText`).
    func inputMethodCommitMarkedText()
    /// Where the caret is, for the input method's candidate window: points, from the bottom left of the
    /// display the springboard shows on.
    func inputMethodCaretRect() -> CGRect?
}

// MARK: - Until a host is chosen

/// The host until one is chosen, as in unit tests: no window, no wallpaper, no glass, no hosted fields, no
/// uninstaller and none of the Dock's resources, a Dock of the default size, and the replicas of the Dock's
/// layer classes.
final class DetachedSpringboardHost: SpringboardHost {
    nonisolated init() {}

    nonisolated var layerFactory: any SpringboardLayerFactory {
        ReplicaSpringboardLayerFactory()
    }

    nonisolated var preferences: UserDefaults {
        .standard
    }

    nonisolated var libraryConfiguration: LaunchpadLibrary.Configuration {
        .standard(itemsPerPage: SpringboardPreferences.itemsPerPage)
    }

    nonisolated var resourceBundle: Bundle? {
        nil
    }

    var dockGeometry: SpringboardDockGeometry {
        .standard
    }

    var iconStyle: SpringboardIconStyle? {
        nil
    }

    var applicationUninstaller: (any SpringboardApplicationUninstaller)? {
        nil
    }

    func makeWindow(onDisplay displayIdentifier: CGDirectDisplayID) -> (any SpringboardWindow)? {
        nil
    }

    func wallpaperImage(onDisplay displayIdentifier: CGDirectDisplayID) -> CGImage? {
        nil
    }

    var offersGlassBackground: Bool {
        false
    }

    func makeGlassBackground(frame: CGRect, scale: CGFloat, backdropGroupName: String) -> (any SpringboardGlassBackground)? {
        nil
    }

    func makeHostedTextField(configuration: SpringboardHostedTextFieldConfiguration) -> (any SpringboardHostedTextField)? {
        nil
    }

    var inputMethod: (any SpringboardInputMethod)? {
        nil
    }

    func isOnDock(_ globalPoint: CGPoint) -> Bool {
        false
    }

    func setDockVisibility(_ visibility: SpringboardDockVisibility) {}
}
