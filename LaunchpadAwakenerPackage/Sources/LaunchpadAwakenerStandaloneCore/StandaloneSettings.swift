import AppKit
import KeyboardShortcuts
import LaunchpadAwakenerSharedUI
import OSToolbox
import ServiceManagement
import SnapKit
import UIFoundation
import UIFoundationToolbox

extension KeyboardShortcuts.Name {
    /// Shows the springboard, or hides it. Not set until the user records one, as macOS 15's "Show
    /// Launchpad" shortcut was not.
    static let toggleLaunchpad = Self("toggleLaunchpad")
}

/// Opening the settings: from the application menu's Settings…, and from the Dock icon's menu while the
/// springboard, covering the menu bar, keeps the application menu out of reach.
@MainActor
enum StandaloneSettings {
    private static let windowController = StandaloneSettingsWindowController()

    /// Brings the settings up. The springboard hides first: it covers the whole screen.
    static func show() {
        StandaloneLaunchpad.shared.hide(reason: "showing the settings", returningToPreviousApplication: false)
        NSApp.activate()
        windowController.showWindow(nil)
        windowController.window?.makeKeyAndOrderFront(nil)
    }
}

/// The settings window: the shortcut that shows Launchpad, and whether it opens at login. A fixed size,
/// as SwiftUI's Settings window was.
private final class StandaloneSettingsWindowController: XiblessWindowController<NSWindow> {
    private let settingsViewController = StandaloneSettingsViewController()

    init() {
        super.init(windowGenerator: NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: StandaloneSettingsViewController.width, height: 0),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: true
        ))
    }

    override func windowDidLoad() {
        super.windowDidLoad()
        contentWindow.title = "Launchpad Settings"
        contentWindow.isReleasedWhenClosed = false
        contentWindow.contentViewController = settingsViewController
        contentWindow.setContentSize(NSSize(width: StandaloneSettingsViewController.width, height: settingsViewController.fittingContentHeight()))
        contentWindow.center()
    }
}

/// The settings' one grouped section: the shortcut recorder, and the switch for opening at login.
private final class StandaloneSettingsViewController: XiblessViewController<XiblessView> {
    static let width: CGFloat = 380

    private let openAtLoginSwitch = NSSwitch()
    private let formView = FormView()

    /// The height that shows the form whole.
    func fittingContentHeight() -> CGFloat {
        loadViewIfNeeded()
        return formView.fittingHeight(forWidth: Self.width)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        let recorder = KeyboardShortcuts.RecorderCocoa(for: .toggleLaunchpad)
        openAtLoginSwitch.box.setAction { [weak self] toggle in
            StandaloneLoginItem.setOpensAtLogin(toggle?.state == .on)
            self?.showOpensAtLogin()
        }

        formView.sections = [
            FormSectionView(rows: [
                FormRowView(title: "Show Launchpad:", accessoryView: recorder),
                FormRowView(title: "Open at Login", accessoryView: openAtLoginSwitch),
            ]),
        ]
        hierarchy {
            formView
        }
        formView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The user can take the app out of Open at Login in System Settings at any time; read it again.
        showOpensAtLogin()
    }

    private func showOpensAtLogin() {
        openAtLoginSwitch.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

/// Opening at login, through `SMAppService.mainApp`: the app appears under Open at Login in System
/// Settings, where the user can also take it out.
@Loggable(subsystem: "com.MxIris.LaunchpadAwakener", category: "StandaloneLoginItem")
@MainActor
enum StandaloneLoginItem {
    static func setOpensAtLogin(_ opensAtLogin: Bool) {
        do {
            if opensAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            #log(.info, "Opens at login: \(opensAtLogin, privacy: .public)")
        } catch {
            #log(.error, "Could not change opening at login to \(opensAtLogin, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }
}
