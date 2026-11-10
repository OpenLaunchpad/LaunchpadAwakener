import AppKit
import AppKitNavigation
import AppKitPlus
import LaunchpadAwakenerAppCore
import LaunchpadAwakenerSharedUI
import SnapKit
import UIFoundation
import UIFoundationToolbox

/// The control panel: the readiness banner over a grouped form — General, Launchpad, Dock Injection, and
/// Last Error when something failed.
///
/// Everything shown describes processes this app does not own, and nothing notifies it when they change:
/// the Dock can be restarted from a terminal, the kill switch created over ssh, the login items switched
/// off in System Settings. So while the panel is on screen it re-checks every few seconds, and stops
/// when the window closes.
final class ControlPanelViewController: XiblessViewController<XiblessView> {
    /// The width the panel is laid out for; its height follows the content, up to the screen.
    static let width: CGFloat = 520

    /// How often the panel re-checks what it shows while it is on screen.
    ///
    /// Frequent enough that restarting the Dock looks immediate, infrequent enough to be unnoticeable:
    /// one `kill(pid, 0)` per known Dock, one status request per open payload channel, and a few
    /// `SMAppService` and file-system reads.
    private static let stateRefreshInterval = Duration.seconds(3)

    private static let bannerInsets = NSEdgeInsets(top: 14, left: 20, bottom: 14, right: 20)

    private let daemonController: PrivilegedDaemonController
    private let injectionCoordinator: PayloadInjectionCoordinator
    private let launchAtLoginController: LaunchAtLoginController
    private let textInputAgentController: TextInputAgentController
    private let killSwitchController: KillSwitchController
    private let standaloneLaunchpadController: StandaloneLaunchpadController
    private let launchProgress: ApplicationLaunchProgress
    /// While SIP is on, the panel is the banner pointing at the standalone app, and the launch at login row.
    private let isInjectionBlockedBySystemIntegrityProtection: Bool
    private let showOrganizer: () -> Void

    private let bannerView = ReadinessBannerView()
    private let bannerContainer = XiblessView()
    private let formView = FormView()
    private lazy var formScrollController = NSScrollViewController(documentView: formView)
    private var refreshTask: Task<Void, Never>?

    // General
    private let launchAtLoginSwitch = NSSwitch()
    private lazy var launchAtLoginRow = FormRowView(title: "Launch at login", subtitle: "Starts with your Mac and stays in the menu bar.", accessoryView: launchAtLoginSwitch)
    private lazy var launchAtLoginWarningRow = FormRowView(contentView: SystemSettingsWarningView(text: "Turned off under System Settings › Login Items.") { [weak self] in
        self?.launchAtLoginController.openLoginItemsSettings()
    })
    private let daemonStatusView = StatusIndicatorView()
    private let daemonProgressIndicator = ControlPanelViewController.makeSpinner()
    private let uninstallDaemonButton = ControlPanelViewController.makeButton(title: "Uninstall", controlSize: .small)
    private let installDaemonButton = ControlPanelViewController.makeButton(title: "Install", controlSize: .small, isProminent: true)
    private lazy var daemonRow = FormRowView(title: "Privileged daemon", accessoryView: Self.makeAccessoryStack([daemonStatusView, daemonProgressIndicator, uninstallDaemonButton, installDaemonButton]))
    private let textInputStatusView = StatusIndicatorView()
    private let registerTextInputButton = ControlPanelViewController.makeButton(title: "Register", controlSize: .small)
    private let restartTextInputButton = ControlPanelViewController.makeButton(title: "Restart", controlSize: .small)
    private lazy var textInputRow = FormRowView(
        title: "Input method helper",
        accessoryView: Self.makeAccessoryStack([textInputStatusView, registerTextInputButton, restartTextInputButton])
    )
    private lazy var textInputWarningRow = FormRowView(contentView: SystemSettingsWarningView(text: "Search and rename fields cannot use input methods.") { [weak self] in
        self?.textInputAgentController.openLoginItemsSettings()
    })

    // Launchpad
    private let killSwitchSwitch = NSSwitch()
    private lazy var killSwitchRow = FormRowView(title: "Open the system's Apps instead", subtitle: "Switches itself off when the Mac restarts.", accessoryView: killSwitchSwitch)
    private let dockBuildStatusView = StatusIndicatorView()
    private lazy var dockBuildRow = FormRowView(title: "Dock build", accessoryView: dockBuildStatusView)
    private let organizeButton = ControlPanelViewController.makeButton(title: "Organize…", controlSize: .regular)
    private lazy var layoutRow = FormRowView(title: "Layout", subtitle: "Move many apps at once, manage folders, group by category.", accessoryView: organizeButton)

    // Dock Injection
    private let injectionStatusView = StatusIndicatorView()
    private lazy var injectionRow = FormRowView(title: "Dock", accessoryView: injectionStatusView)
    private let automaticInjectionSwitch = NSSwitch()
    private lazy var automaticInjectionRow = FormRowView(title: "Re-inject automatically", subtitle: "", accessoryView: automaticInjectionSwitch)
    private let injectNowButton = ControlPanelViewController.makeButton(title: "Inject Now", controlSize: .regular, isProminent: true)
    private let restartDockButton = ControlPanelViewController.makeButton(title: "Restart Dock", controlSize: .regular)
    private let injectionProgressIndicator = ControlPanelViewController.makeSpinner()
    private let injectionMessageLabel = NSTextField(labelWithString: "")
    private lazy var injectionActionsRow = FormRowView(contentView: makeInjectionActions())

    private let errorSection = FormSectionView(title: "Last Error", symbolName: "exclamationmark.triangle.fill")

    init(
        daemonController: PrivilegedDaemonController,
        injectionCoordinator: PayloadInjectionCoordinator,
        launchAtLoginController: LaunchAtLoginController,
        textInputAgentController: TextInputAgentController,
        killSwitchController: KillSwitchController,
        standaloneLaunchpadController: StandaloneLaunchpadController,
        launchProgress: ApplicationLaunchProgress,
        isInjectionBlockedBySystemIntegrityProtection: Bool,
        showOrganizer: @escaping () -> Void
    ) {
        self.daemonController = daemonController
        self.injectionCoordinator = injectionCoordinator
        self.launchAtLoginController = launchAtLoginController
        self.textInputAgentController = textInputAgentController
        self.killSwitchController = killSwitchController
        self.standaloneLaunchpadController = standaloneLaunchpadController
        self.launchProgress = launchProgress
        self.isInjectionBlockedBySystemIntegrityProtection = isInjectionBlockedBySystemIntegrityProtection
        self.showOrganizer = showOrganizer
        super.init()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        buildForm()
        wireActions()
        observeState()

        bannerContainer.hierarchy {
            bannerView
        }
        bannerView.snp.makeConstraints { make in
            make.edges.equalToSuperview().inset(Self.bannerInsets)
        }
        let divider = NSBox()
        divider.boxType = .separator

        hierarchy {
            bannerContainer
            divider
            formScrollController
        }
        bannerContainer.snp.makeConstraints { make in
            make.top.leading.trailing.equalToSuperview()
        }
        divider.snp.makeConstraints { make in
            make.top.equalTo(bannerContainer.snp.bottom)
            make.leading.trailing.equalToSuperview()
        }
        formScrollController.view.snp.makeConstraints { make in
            make.top.equalTo(divider.snp.bottom)
            make.leading.trailing.bottom.equalToSuperview()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        refreshEverything()
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                guard
                    let injectionCoordinator = self?.injectionCoordinator,
                    let isInjectionBlocked = self?.isInjectionBlockedBySystemIntegrityProtection
                else { return }
                // Nothing is ever injected while SIP is on, so there is no payload to ask.
                if !isInjectionBlocked {
                    await injectionCoordinator.refreshState()
                }
                self?.refreshEverything()
                try? await Task.sleep(for: Self.stateRefreshInterval)
            }
        }
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        refreshTask?.cancel()
        refreshTask = nil
    }

    /// The content height that shows the banner and the whole form without scrolling.
    func fittingContentHeight(forWidth width: CGFloat) -> CGFloat {
        loadViewIfNeeded()
        let bannerHeight = bannerView.fittingSize.height + Self.bannerInsets.top + Self.bannerInsets.bottom
        let dividerHeight: CGFloat = 1
        return bannerHeight + dividerHeight + formView.fittingHeight(forWidth: width)
    }

    private func refreshEverything() {
        daemonController.refreshStatus()
        launchAtLoginController.refreshStatus()
        textInputAgentController.refreshStatus()
        killSwitchController.refreshStatus()
        if isInjectionBlockedBySystemIntegrityProtection {
            standaloneLaunchpadController.refreshStatus()
        }
    }

    // MARK: - Building

    private func buildForm() {
        launchAtLoginRow.toolTip = Self.launchAtLoginHelp
        daemonRow.toolTip = "Injects the payload into the Dock, which needs root. System Settings asks you to approve it once, under General › Login Items."
        textInputRow.toolTip = Self.textInputHelp
        restartTextInputButton.toolTip = "Ends the helper. launchd starts this app's copy the next time Launchpad opens."
        killSwitchRow.toolTip = "Every way of opening Apps goes to the system's Apps while this is on. Takes effect at once."
        layoutRow.toolTip = "Opens a window listing Launchpad's pages and folders. Changes go to the Dock right away and show the next time Launchpad opens."
        restartDockButton.toolTip = "Only needed after installing a new build: the payload already in the Dock cannot be replaced while it runs. The new Dock is injected right away."
        errorSection.headerTintColor = .systemRed
        errorSection.isHidden = true

        // Every other row is about injecting into the Dock, which SIP rules out. Launch at login stays, so
        // that an app left starting at login from before SIP was turned on can be stopped from here.
        guard !isInjectionBlockedBySystemIntegrityProtection else {
            formView.sections = [
                FormSectionView(title: "General", symbolName: "gearshape.fill", rows: [
                    launchAtLoginRow,
                    launchAtLoginWarningRow,
                ]),
                errorSection,
            ]
            return
        }

        formView.sections = [
            FormSectionView(title: "General", symbolName: "gearshape.fill", rows: [
                launchAtLoginRow,
                launchAtLoginWarningRow,
                daemonRow,
                textInputRow,
                textInputWarningRow,
            ]),
            FormSectionView(title: "Launchpad", symbolName: "square.grid.3x3.fill", rows: [
                killSwitchRow,
                dockBuildRow,
                layoutRow,
            ]),
            FormSectionView(title: "Dock Injection", symbolName: "arrow.down.circle.fill", rows: [
                injectionRow,
                automaticInjectionRow,
                injectionActionsRow,
            ]),
            errorSection,
        ]
    }

    private func makeInjectionActions() -> NSView {
        injectionMessageLabel.font = .preferredFont(forTextStyle: .callout)
        injectionMessageLabel.lineBreakMode = .byTruncatingTail
        injectionMessageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        injectionMessageLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let stackView = NSStackView(views: [injectNowButton, restartDockButton, injectionProgressIndicator, injectionMessageLabel])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 8
        stackView.detachesHiddenViews = true
        return stackView
    }

    private func wireActions() {
        bannerView.performAction = { [weak self] action in
            self?.perform(action)
        }
        launchAtLoginSwitch.box.setAction { [weak self] toggle in
            self?.launchAtLoginController.setEnabled(toggle?.state == .on)
        }
        uninstallDaemonButton.hasDestructiveAction = true
        uninstallDaemonButton.box.setAction { [weak self] _ in
            guard let daemonController = self?.daemonController else { return }
            Task { await daemonController.uninstall() }
        }
        installDaemonButton.box.setAction { [weak self] _ in
            guard let daemonController = self?.daemonController else { return }
            Task { await daemonController.install() }
        }
        registerTextInputButton.box.setAction { [weak self] _ in
            self?.textInputAgentController.registerIfNeeded()
        }
        restartTextInputButton.box.setAction { [weak self] _ in
            self?.textInputAgentController.restartHelper()
        }
        killSwitchSwitch.box.setAction { [weak self] toggle in
            self?.killSwitchController.setEngaged(toggle?.state == .on)
        }
        organizeButton.box.setAction { [weak self] _ in
            self?.showOrganizer()
        }
        automaticInjectionSwitch.box.setAction { [weak self] toggle in
            self?.injectionCoordinator.setAutomaticInjectionEnabled(toggle?.state == .on)
        }
        injectNowButton.box.setAction { [weak self] _ in
            guard let injectionCoordinator = self?.injectionCoordinator else { return }
            Task { await injectionCoordinator.injectIntoRunningTargets() }
        }
        restartDockButton.box.setAction { [weak self] _ in
            self?.injectionCoordinator.restartTargets()
        }
    }

    private func perform(_ action: ReadinessAction) {
        switch action {
        case .installDaemon:
            Task { [daemonController] in await daemonController.install() }
        case .openLoginItems:
            launchAtLoginController.openLoginItemsSettings()
        case .turnLaunchpadBackOn:
            killSwitchController.setEngaged(false)
        case .injectNow:
            Task { [injectionCoordinator] in await injectionCoordinator.injectIntoRunningTargets() }
        case .restartDock:
            injectionCoordinator.restartTargets()
        case .installStandaloneLaunchpad:
            Task { [standaloneLaunchpadController] in await standaloneLaunchpadController.installAndOpen() }
        case .openStandaloneLaunchpad:
            standaloneLaunchpadController.open()
        }
    }

    // MARK: - Following the state

    /// One closure per group of rows that change together, so that a change redraws only its rows.
    private func observeState() {
        observe { [unowned self] in
            let readiness = ControlPanelReadiness.evaluate(
                isInjectionBlockedBySystemIntegrityProtection: isInjectionBlockedBySystemIntegrityProtection,
                isStandaloneLaunchpadInstalled: standaloneLaunchpadController.isInstalled,
                launchPhase: launchProgress.phase,
                daemonStatus: daemonController.registrationStatus,
                isKillSwitchEngaged: killSwitchController.isEngaged,
                isInjected: !injectionCoordinator.injectedProcessIdentifiers.isEmpty,
                residentPayloads: injectionCoordinator.residentPayloads
            )
            let presentation = ReadinessPresentation(readiness)
            bannerView.show(presentation, isActionEnabled: isEnabled(presentation.action))
        }

        observe { [weak self] in
            guard let self else { return }
            launchAtLoginSwitch.state = launchAtLoginController.isEnabled ? .on : .off
            launchAtLoginWarningRow.isHidden = !launchAtLoginController.isDisabledInSystemSettings
        }

        observe { [weak self] in
            guard let self else { return }
            daemonStatusView.show(text: daemonController.statusMessage, tint: StatusTint(daemonController.registrationStatus))
            let isChanging = daemonController.isPerformingRegistrationChange
            daemonProgressIndicator.isHidden = !isChanging
            if isChanging {
                daemonProgressIndicator.startAnimation(nil)
            } else {
                daemonProgressIndicator.stopAnimation(nil)
            }
            uninstallDaemonButton.isHidden = isChanging || !daemonController.isEnabled
            installDaemonButton.isHidden = isChanging || daemonController.isEnabled
        }

        observe { [weak self] in
            guard let self else { return }
            let textInputStatus = textInputAgentController.statusLine
            textInputStatusView.show(textInputStatus)
            textInputRow.toolTip = textInputStatus.help.isEmpty ? Self.textInputHelp : "\(Self.textInputHelp)\n\n\(textInputStatus.help)"
            registerTextInputButton.isHidden = textInputAgentController.registrationStatus != .notRegistered
            restartTextInputButton.isHidden = textInputAgentController.registrationStatus != .enabled || !textInputAgentController.canRestartHelper
            textInputWarningRow.isHidden = !textInputAgentController.isDisabledInSystemSettings
        }

        observe { [weak self] in
            guard let self else { return }
            killSwitchSwitch.state = killSwitchController.isEngaged ? .on : .off
        }

        observe { [weak self] in
            guard let self else { return }
            let dockBuild = StatusLine.dockBuild(reportedBy: injectionCoordinator.residentPayloads.first)
            dockBuildStatusView.show(dockBuild)
            dockBuildRow.toolTip = dockBuild.help
            let injection = StatusLine.injection(
                injectedProcessIdentifiers: injectionCoordinator.injectedProcessIdentifiers,
                residentPayloads: injectionCoordinator.residentPayloads
            )
            injectionStatusView.show(injection)
            injectionRow.toolTip = injection.help.isEmpty ? nil : injection.help
        }

        observe { [weak self] in
            guard let self else { return }
            let isAutomatic = injectionCoordinator.isAutomaticInjectionEnabled
            automaticInjectionSwitch.state = isAutomatic ? .on : .off
            // The button below re-injects on its own, so what is left is a Dock that goes away without this
            // app asking: crashed, killed from a terminal, or replaced at login.
            automaticInjectionRow.subtitle = isAutomatic
                ? "After the Dock restarts on its own."
                : "Off: a Dock that restarts on its own comes back with the system's Apps."
            automaticInjectionRow.subtitleTextColor = isAutomatic ? .secondaryLabelColor : .systemOrange
            automaticInjectionSwitch.isEnabled = daemonController.isEnabled
            automaticInjectionRow.isEnabled = daemonController.isEnabled
        }

        observe { [weak self] in
            guard let self else { return }
            let isBusy = injectionCoordinator.isBusy
            injectNowButton.isEnabled = daemonController.isEnabled && !isBusy
            restartDockButton.isEnabled = !isBusy
            injectionProgressIndicator.isHidden = !isBusy
            if isBusy {
                injectionProgressIndicator.startAnimation(nil)
            } else {
                injectionProgressIndicator.stopAnimation(nil)
            }
            // Injection can legitimately do nothing — no Dock running, or already injected — and a button
            // that silently does nothing looks broken; the row above says the rest.
            if injectionCoordinator.isWaitingForTargetRestart {
                injectionMessageLabel.attributedStringValue = NSAttributedString(string: "Waiting for the Dock…", attributes: [.foregroundColor: NSColor.secondaryLabelColor])
                injectionMessageLabel.toolTip = nil
                injectionMessageLabel.isHidden = false
            } else if let report = injectionCoordinator.lastInjectionReport, report.isFailure {
                injectionMessageLabel.attributedStringValue = Self.failureText(report.summary)
                injectionMessageLabel.toolTip = report.summary
                injectionMessageLabel.isHidden = false
            } else {
                injectionMessageLabel.isHidden = true
            }
        }

        // Every outstanding error, not just the first one found: showing one and swallowing the rest hides
        // exactly the case worth seeing, two things failing at once.
        observe { [weak self] in
            guard let self else { return }
            let errorDescriptions = [
                ("Startup", launchAtLoginController.lastErrorDescription),
                ("Injection", injectionCoordinator.lastErrorDescription),
                ("Input method helper", textInputAgentController.lastErrorDescription),
                ("Kill switch", killSwitchController.lastErrorDescription),
                ("Standalone Launchpad", standaloneLaunchpadController.lastErrorDescription),
            ].compactMap { label, description in description.map { (label: label, description: $0) } }
            errorSection.rows = errorDescriptions.map { FormRowView(contentView: ErrorDescriptionView(label: $0.label, description: $0.description)) }
            errorSection.isHidden = errorDescriptions.isEmpty
        }
    }

    private func isEnabled(_ action: ReadinessAction?) -> Bool {
        switch action {
        case .installDaemon:
            !daemonController.isPerformingRegistrationChange
        case .injectNow, .restartDock:
            !injectionCoordinator.isBusy
        case .installStandaloneLaunchpad:
            standaloneLaunchpadController.canInstall && !standaloneLaunchpadController.isInstalling
        case .openLoginItems, .turnLaunchpadBackOn, .openStandaloneLaunchpad, nil:
            true
        }
    }

    // MARK: - Small pieces

    private static var launchAtLoginHelp: String {
        #if DEBUG
        // The login item records this build product's path. Nothing warns the user when that path stops
        // existing — login simply fails to launch anything, silently.
        "The window stays closed at login; open it from the menu bar icon. Debug build: the login item points at this build's path, and debug and release builds share one login item — whichever registered last wins."
        #else
        "The window stays closed at login; open it from the menu bar icon."
        #endif
    }

    private static let textInputHelp = "Hosts the search and rename fields so that input methods such as Pinyin work in them. Once started, it keeps running until you log out; reinstalling the daemon does not restart it."

    private static func failureText(_ summary: String) -> NSAttributedString {
        let font = NSFont.preferredFont(forTextStyle: .callout)
        let symbol = NSTextAttachment()
        symbol.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: font.pointSize, weight: .regular))
        let text = NSMutableAttributedString(attachment: symbol)
        text.append(NSAttributedString(string: " " + summary))
        text.addAttributes([.foregroundColor: NSColor.systemRed, .font: font], range: NSRange(location: 0, length: text.length))
        return text
    }

    private static func makeButton(title: String, controlSize: NSControl.ControlSize, isProminent: Bool = false) -> NSButton {
        let button = NSButton(title: title, target: nil, action: nil)
        button.bezelStyle = .push
        button.controlSize = controlSize
        button.font = .systemFont(ofSize: NSFont.systemFontSize(for: controlSize))
        if isProminent {
            button.bezelColor = .controlAccentColor
            if #available(macOS 26.0, *) {
                button.tintProminence = .primary
            }
        }
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        return button
    }

    private static func makeSpinner() -> NSProgressIndicator {
        let progressIndicator = NSProgressIndicator()
        progressIndicator.style = .spinning
        progressIndicator.controlSize = .small
        progressIndicator.isDisplayedWhenStopped = false
        progressIndicator.isHidden = true
        return progressIndicator
    }

    private static func makeAccessoryStack(_ views: [NSView]) -> NSStackView {
        let stackView = NSStackView(views: views)
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.spacing = 10
        stackView.detachesHiddenViews = true
        return stackView
    }
}

/// One row of the Last Error section: what failed on the leading side, the error in red, selectable and
/// wrapping, on the trailing side.
private final class ErrorDescriptionView: XiblessView {
    private let descriptionLabel: NSTextField

    init(label: String, description: String) {
        descriptionLabel = NSTextField(wrappingLabelWithString: description)
        super.init(frame: .zero)
        let titleLabel = NSTextField(labelWithString: label)
        titleLabel.font = .preferredFont(forTextStyle: .body)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        descriptionLabel.font = .preferredFont(forTextStyle: .body)
        descriptionLabel.textColor = .systemRed
        descriptionLabel.alignment = .right
        descriptionLabel.isSelectable = true
        descriptionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        descriptionLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let stackView = NSStackView(views: [titleLabel, descriptionLabel])
        stackView.orientation = .horizontal
        stackView.alignment = .centerY
        stackView.distribution = .fill
        stackView.spacing = FormRowView.accessorySpacing
        hierarchy {
            stackView
        }
        stackView.snp.makeConstraints { make in
            make.edges.equalToSuperview()
        }
    }

    override func layout() {
        super.layout()
        let descriptionWidth = descriptionLabel.frame.width
        if descriptionWidth > 0, descriptionLabel.preferredMaxLayoutWidth != descriptionWidth {
            descriptionLabel.preferredMaxLayoutWidth = descriptionWidth
            needsLayout = true
        }
    }
}
