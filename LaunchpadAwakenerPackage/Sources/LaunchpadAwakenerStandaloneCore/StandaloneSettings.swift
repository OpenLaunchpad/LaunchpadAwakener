import AppKit
import AppKitNavigation
import KeyboardShortcuts
import LaunchpadAwakenerSharedUI
import LaunchpadAwakenerUpdating
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

/// The settings window: the shortcut that shows Launchpad, whether it opens at login, and its updates. A
/// fixed size, as SwiftUI's Settings window was.
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

/// The settings' one grouped section: the shortcut recorder, the switch for opening at login, and the
/// app's updates.
private final class StandaloneSettingsViewController: XiblessViewController<XiblessView> {
    static let width: CGFloat = 380

    private let openAtLoginSwitch = NSSwitch()
    private let automaticUpdatesSwitch = NSSwitch()
    private let checkForUpdatesButton = NSButton(title: "Check Now", target: nil, action: nil)
    private let formView = FormView()
    private var updater: ApplicationUpdater {
        StandaloneLaunchpad.shared.updater
    }

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

        automaticUpdatesSwitch.box.setAction { [weak self] toggle in
            self?.updater.automaticallyChecksForUpdates = toggle?.state == .on
        }
        checkForUpdatesButton.controlSize = .small
        checkForUpdatesButton.box.setAction { [weak self] _ in
            self?.updater.checkForUpdates()
        }

        let updatesRow = FormRowView(title: "Updates:", subtitle: updater.currentVersionDescription, accessoryView: checkForUpdatesButton)
        // None in a development build launched without a feed, where nothing checks.
        let updateRows = updater.isStarted ? [
            FormRowView(title: "Check for Updates Automatically:", accessoryView: automaticUpdatesSwitch),
            updatesRow,
        ] : []
        formView.sections = [
            FormSectionView(rows: [
                FormRowView(title: "Show Launchpad:", accessoryView: recorder),
                FormRowView(title: "Open at Login", accessoryView: openAtLoginSwitch),
            ] + updateRows),
        ]
        hierarchy {
            formView
        }
        formView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }

        observe { [weak self] in
            guard let self else { return }
            if let pendingUpdate = updater.pendingUpdate {
                updatesRow.subtitle = "Version \(pendingUpdate.displayVersion) is available."
                checkForUpdatesButton.title = "Install…"
            } else {
                updatesRow.subtitle = updater.currentVersionDescription
                checkForUpdatesButton.title = "Check Now"
            }
        }
    }

    override func viewWillAppear() {
        super.viewWillAppear()
        // The user can take the app out of Open at Login in System Settings at any time; read it again.
        showOpensAtLogin()
        // Sparkle's own setting, which its window's checkbox changes too.
        automaticUpdatesSwitch.state = updater.automaticallyChecksForUpdates ? .on : .off
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
