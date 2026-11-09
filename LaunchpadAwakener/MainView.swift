import SwiftUI
import AppKit
import ServiceManagement
import LaunchpadAwakenerAppCore

struct MainView: View {
    @Environment(PrivilegedDaemonController.self) private var daemonController
    @Environment(PayloadInjectionCoordinator.self) private var injectionCoordinator
    @Environment(LaunchAtLoginController.self) private var launchAtLoginController
    @Environment(TextInputAgentController.self) private var textInputAgentController
    @Environment(KillSwitchController.self) private var killSwitchController

    /// How often the window re-checks what it is displaying while it is open.
    ///
    /// Frequent enough that restarting the Dock looks immediate, infrequent enough to be unnoticeable:
    /// one `kill(pid, 0)` per known Dock, one status request per open payload channel, and a few
    /// `SMAppService` and file-system reads.
    private static let stateRefreshInterval = Duration.seconds(3)

    /// The width the window is laid out for; its height follows the content, up to the screen.
    static let width: CGFloat = 520

    var body: some View {
        VStack(spacing: 0) {
            ReadinessBannerSection()
                .padding(.horizontal, 20)
                .padding(.vertical, 14)

            Divider()

            // Not `fixedSize`: a form that insists on its full height cannot be shorter than the
            // screen when its content is taller, and the window then reached down behind the Dock.
            // The form's ideal height is still its content's, which is what
            // `defaultWindowPlacement` opens the window at, capped to the screen; anything past
            // that scrolls.
            Form {
                GeneralSection()
                LaunchpadSection()
                InjectionSection()
                ErrorSection()
            }
            .formStyle(.grouped)
        }
        .frame(width: Self.width)
        .frame(minHeight: 320)
        .onAppear { refreshEverything() }
        // Everything shown here describes processes this app does not own, and nothing notifies it
        // when they change: the Dock can be restarted from a terminal, the kill switch created over
        // ssh, the login items switched off in System Settings. `.task` rather than a timer ties the
        // polling to the window being on screen — it is cancelled when the window closes.
        .task {
            while !Task.isCancelled {
                await injectionCoordinator.refreshState()
                refreshEverything()
                try? await Task.sleep(for: Self.stateRefreshInterval)
            }
        }
    }

    private func refreshEverything() {
        daemonController.refreshStatus()
        launchAtLoginController.refreshStatus()
        textInputAgentController.refreshStatus()
        killSwitchController.refreshStatus()
    }
}

// MARK: - Readiness

/// The banner, with the one-click next step where there is one.
private struct ReadinessBannerSection: View {
    @Environment(PrivilegedDaemonController.self) private var daemonController
    @Environment(PayloadInjectionCoordinator.self) private var injectionCoordinator
    @Environment(LaunchAtLoginController.self) private var launchAtLoginController
    @Environment(ApplicationLaunchProgress.self) private var launchProgress
    @Environment(KillSwitchController.self) private var killSwitchController

    var body: some View {
        let readiness = ControlPanelReadiness.evaluate(
            launchPhase: launchProgress.phase,
            daemonStatus: daemonController.registrationStatus,
            isKillSwitchEngaged: killSwitchController.isEngaged,
            isInjected: !injectionCoordinator.injectedProcessIdentifiers.isEmpty,
            residentPayloads: injectionCoordinator.residentPayloads
        )
        ReadinessBanner(presentation: ReadinessPresentation(readiness), action: action(for: readiness))
    }

    private func action(for readiness: ControlPanelReadiness) -> ReadinessBanner.Action? {
        switch readiness {
        case .daemonNotInstalled:
            return ReadinessBanner.Action(title: "Install", isEnabled: !daemonController.isPerformingRegistrationChange) {
                Task { await daemonController.install() }
            }
        case .awaitingDaemonApproval:
            return ReadinessBanner.Action(title: "Open Login Items", isEnabled: true) {
                launchAtLoginController.openLoginItemsSettings()
            }
        case .killSwitchEngaged:
            return ReadinessBanner.Action(title: "Turn Back On", isEnabled: true) {
                killSwitchController.setEngaged(false)
            }
        case .notInjected, .startupStopped:
            return ReadinessBanner.Action(title: "Inject Now", isEnabled: !injectionCoordinator.isBusy) {
                Task { await injectionCoordinator.injectIntoRunningTargets() }
            }
        case .stalePayload:
            return ReadinessBanner.Action(title: "Restart Dock", isEnabled: !injectionCoordinator.isBusy) {
                injectionCoordinator.restartTargets()
            }
        case .startingUp, .daemonMissingFromBundle, .hooksNotInstalled, .active:
            return nil
        }
    }
}

// MARK: - General

/// What has to be in place for the tool to work at all: starting with the Mac, the daemon, the
/// input method helper. One row each; the explanations are in the help tags.
private struct GeneralSection: View {
    @Environment(PrivilegedDaemonController.self) private var daemonController
    @Environment(LaunchAtLoginController.self) private var launchAtLoginController
    @Environment(TextInputAgentController.self) private var textInputAgentController

    var body: some View {
        Section {
            Toggle(isOn: launchAtLoginBinding) {
                Text("Launch at login")
                Text("Starts with your Mac and stays in the menu bar.")
            }
            .help(Self.launchAtLoginHelp)

            if launchAtLoginController.isDisabledInSystemSettings {
                SystemSettingsWarning(
                    text: "Turned off under System Settings › Login Items.",
                    openLoginItems: launchAtLoginController.openLoginItemsSettings
                )
            }

            LabeledContent("Privileged daemon") {
                HStack(spacing: 10) {
                    StatusIndicator(text: daemonController.statusMessage, tint: Self.tint(of: daemonController.registrationStatus))
                    if daemonController.isPerformingRegistrationChange {
                        ProgressView().controlSize(.small)
                    } else if daemonController.isEnabled {
                        Button("Uninstall", role: .destructive) {
                            Task { await daemonController.uninstall() }
                        }
                        .controlSize(.small)
                    } else {
                        Button("Install") {
                            Task { await daemonController.install() }
                        }
                        .controlSize(.small)
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
            .help("Injects the payload into the Dock, which needs root. System Settings asks you to approve it once, under General › Login Items.")

            LabeledContent("Input method helper") {
                HStack(spacing: 10) {
                    StatusIndicator(text: textInputAgentController.statusMessage, tint: Self.tint(of: textInputAgentController.registrationStatus))
                    if textInputAgentController.registrationStatus == .notRegistered {
                        Button("Register") {
                            textInputAgentController.registerIfNeeded()
                        }
                        .controlSize(.small)
                    }
                }
            }
            .help("Hosts the search and rename fields so that input methods such as Pinyin work in them.")

            if textInputAgentController.isDisabledInSystemSettings {
                SystemSettingsWarning(
                    text: "Search and rename fields cannot use input methods.",
                    openLoginItems: textInputAgentController.openLoginItemsSettings
                )
            }
        } header: {
            Label("General", systemImage: "gearshape.fill")
        }
    }

    private static var launchAtLoginHelp: String {
        #if DEBUG
        // The login item records this build product's path. Nothing warns the user when that path
        // stops existing — login simply fails to launch anything, silently.
        "The window stays closed at login; open it from the menu bar icon. Debug build: the login item points at this build's path, and debug and release builds share one login item — whichever registered last wins."
        #else
        "The window stays closed at login; open it from the menu bar icon."
        #endif
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginController.isEnabled },
            set: { launchAtLoginController.setEnabled($0) }
        )
    }

    static func tint(of status: SMAppService.Status) -> Color {
        switch status {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notFound: return .red
        default: return .secondary
        }
    }
}

// MARK: - Launchpad

/// What the Dock does with Apps: the kill switch, and whether this Dock build is one the payload knows.
private struct LaunchpadSection: View {
    @Environment(PayloadInjectionCoordinator.self) private var injectionCoordinator
    @Environment(KillSwitchController.self) private var killSwitchController

    var body: some View {
        Section {
            Toggle(isOn: killSwitchBinding) {
                Text("Open the system's Apps instead")
                Text("Switches itself off when the Mac restarts.")
            }
            .help("Every way of opening Apps goes to the system's Apps while this is on. Takes effect at once.")

            LabeledContent("Dock build") {
                StatusIndicator(text: dockBuildDescription, tint: dockBuildTint)
            }
            .help(dockBuildHelp)
        } header: {
            Label("Launchpad", systemImage: "square.grid.3x3.fill")
        }
    }

    /// The first Dock that answered. There is one Dock per login session, so in practice the only one.
    private var reportingPayload: PayloadInjectionCoordinator.ResidentPayload? {
        injectionCoordinator.residentPayloads.first
    }

    private var dockBuildDescription: String {
        guard let payload = reportingPayload else {
            return "Known once the Dock is injected"
        }
        switch payload.hookState {
        case .installed where payload.areHooksInstalled:
            let release = payload.dockSystemReleases.last.map { "macOS \($0)" } ?? "Known build"
            return "\(release) · supported"
        case .installed:
            return "No hooks declared"
        case .unknownDockBuild:
            return "Unknown build — not supported"
        case .incompatibleDockMethods:
            return "Methods do not match"
        case .failed:
            return "Hooks failed to install"
        }
    }

    private var dockBuildTint: Color {
        guard let payload = reportingPayload else { return .secondary }
        return payload.areHooksInstalled ? .green : .red
    }

    private var dockBuildHelp: String {
        guard let payload = reportingPayload else {
            return "The payload reports the Dock build once it is in the Dock."
        }
        var lines: [String] = []
        if let dockBundleVersion = payload.dockBundleVersion {
            lines.append("Dock \(dockBundleVersion)")
        }
        if !payload.dockSystemReleases.isEmpty {
            lines.append("Ships with macOS \(payload.dockSystemReleases.joined(separator: ", "))")
        }
        switch payload.hookState {
        case .unknownDockBuild(let executableUUID):
            lines.append("Executable UUID \(executableUUID)")
        case .failed(let description):
            lines.append(description)
        case .installed, .incompatibleDockMethods:
            break
        }
        return lines.joined(separator: "\n")
    }

    private var killSwitchBinding: Binding<Bool> {
        Binding(
            get: { killSwitchController.isEngaged },
            set: { killSwitchController.setEngaged($0) }
        )
    }
}

// MARK: - Injection

private struct InjectionSection: View {
    @Environment(PrivilegedDaemonController.self) private var daemonController
    @Environment(PayloadInjectionCoordinator.self) private var injectionCoordinator

    var body: some View {
        Section {
            LabeledContent("Dock") {
                StatusIndicator(text: injectionDescription, tint: injectionTint)
            }
            .help(payloadHelp)

            Toggle(isOn: automaticInjectionBinding) {
                Text("Re-inject automatically")
                // The button below re-injects on its own, so what is left is a Dock that goes away
                // without this app asking: crashed, killed from a terminal, or replaced at login.
                Text(injectionCoordinator.isAutomaticInjectionEnabled
                     ? "After the Dock restarts on its own."
                     : "Off: a Dock that restarts on its own comes back with the system's Apps.")
                    .foregroundStyle(injectionCoordinator.isAutomaticInjectionEnabled ? Color.secondary : Color.orange)
            }
            .disabled(!daemonController.isEnabled)

            HStack {
                Button("Inject Now") {
                    Task { await injectionCoordinator.injectIntoRunningTargets() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!daemonController.isEnabled || injectionCoordinator.isBusy)

                Button("Restart Dock") {
                    injectionCoordinator.restartTargets()
                }
                .disabled(injectionCoordinator.isBusy)
                .help("Only needed after installing a new build: the payload already in the Dock cannot be replaced while it runs. The new Dock is injected right away.")

                if injectionCoordinator.isBusy {
                    ProgressView().controlSize(.small)
                }

                Spacer(minLength: 8)

                // Injection can legitimately do nothing — no Dock running, or already injected — and
                // a button that silently does nothing looks broken; the row above says the rest.
                if injectionCoordinator.isWaitingForTargetRestart {
                    Text("Waiting for the Dock…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else if let report = injectionCoordinator.lastInjectionReport, report.isFailure {
                    Label(report.summary, systemImage: "xmark.circle.fill")
                        .font(.callout)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(report.summary)
                }
            }
        } header: {
            Label("Dock Injection", systemImage: "arrow.down.circle.fill")
        }
    }

    /// One line for the Dock: which process, and what its payload says about itself.
    private var injectionDescription: String {
        let processIdentifiers = injectionCoordinator.injectedProcessIdentifiers.sorted()
        guard let processIdentifier = processIdentifiers.first else { return "Not injected" }
        guard let payload = injectionCoordinator.residentPayloads.first(where: { $0.hostProcessIdentifier == processIdentifier }) else {
            // Injected, but the payload has not answered — still connecting, or its channel dropped.
            return "Injected · process \(processIdentifier)"
        }
        let buildDescription = payload.isStale ? "older build" : "current build"
        guard case .installed(let hookCount) = payload.hookState, hookCount > 0 else {
            return "Process \(processIdentifier) · \(buildDescription) · no hooks"
        }
        return "Process \(processIdentifier) · \(buildDescription) · \(hookCount) hook\(hookCount == 1 ? "" : "s")"
    }

    private var injectionTint: Color {
        guard let processIdentifier = injectionCoordinator.injectedProcessIdentifiers.min() else { return .orange }
        guard let payload = injectionCoordinator.residentPayloads.first(where: { $0.hostProcessIdentifier == processIdentifier }) else {
            return .green
        }
        guard payload.areHooksInstalled else { return .red }
        return payload.isStale ? .orange : .green
    }

    private var payloadHelp: String {
        injectionCoordinator.residentPayloads
            .map { "\($0.hostProcessName) \($0.hostProcessIdentifier): payload image \($0.imageUUID.uuidString)" }
            .joined(separator: "\n")
    }

    private var automaticInjectionBinding: Binding<Bool> {
        Binding(
            get: { injectionCoordinator.isAutomaticInjectionEnabled },
            set: { injectionCoordinator.setAutomaticInjectionEnabled($0) }
        )
    }
}

// MARK: - Errors

/// Every outstanding error, not just the first one found.
///
/// Showing one and swallowing the rest hides exactly the case worth seeing: two things failing at
/// once, where fixing the visible half changes nothing and there is no sign of the other.
private struct ErrorSection: View {
    @Environment(PayloadInjectionCoordinator.self) private var injectionCoordinator
    @Environment(LaunchAtLoginController.self) private var launchAtLoginController
    @Environment(TextInputAgentController.self) private var textInputAgentController
    @Environment(KillSwitchController.self) private var killSwitchController

    var body: some View {
        let errorDescriptions = [
            ("Startup", launchAtLoginController.lastErrorDescription),
            ("Injection", injectionCoordinator.lastErrorDescription),
            ("Input method helper", textInputAgentController.lastErrorDescription),
            ("Kill switch", killSwitchController.lastErrorDescription),
        ].compactMap { label, description in description.map { (label: label, description: $0) } }

        if !errorDescriptions.isEmpty {
            Section {
                ForEach(errorDescriptions, id: \.label) { errorDescription in
                    LabeledContent(errorDescription.label) {
                        Text(errorDescription.description)
                            .foregroundStyle(.red)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.trailing)
                    }
                }
            } header: {
                Label("Last Error", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
        }
    }
}

// MARK: - Readiness banner

/// How one ``ControlPanelReadiness`` reads in the banner.
struct ReadinessPresentation {
    let title: String
    let nextStep: String
    let systemImageName: String
    let tint: Color

    init(_ readiness: ControlPanelReadiness) {
        switch readiness {
        case .startingUp(let progressDescription):
            self.init(title: "Starting up", nextStep: progressDescription, systemImageName: "hourglass.circle.fill", tint: .blue)
        case .awaitingDaemonApproval:
            self.init(
                title: "Waiting for approval",
                nextStep: "Approve “LaunchpadAwakener” under System Settings › General › Login Items.",
                systemImageName: "hand.raised.circle.fill",
                tint: .orange
            )
        case .daemonMissingFromBundle:
            self.init(
                title: "Daemon missing from the app bundle",
                nextStep: "The build did not embed the daemon. Rebuild with ./RunScript.sh.",
                systemImageName: "exclamationmark.triangle.fill",
                tint: .red
            )
        case .daemonNotInstalled:
            self.init(
                title: "Not installed",
                nextStep: "Install the privileged daemon to get started.",
                systemImageName: "circle.dashed",
                tint: .secondary
            )
        case .killSwitchEngaged:
            self.init(
                title: "Paused",
                nextStep: "The Dock opens the system's Apps until Launchpad is turned back on.",
                systemImageName: "pause.circle.fill",
                tint: .indigo
            )
        case .startupStopped(let reason):
            self.init(title: "Startup did not finish", nextStep: reason, systemImageName: "exclamationmark.triangle.fill", tint: .orange)
        case .notInjected:
            self.init(
                title: "Not injected",
                nextStep: "The daemon is ready. Inject into the Dock to replace Apps with Launchpad.",
                systemImageName: "bolt.horizontal.circle.fill",
                tint: .orange
            )
        case .hooksNotInstalled(let hookState):
            let title: String
            let reason: String
            switch hookState {
            case .unknownDockBuild:
                title = "This Dock build is not supported"
                reason = "LaunchpadAwakener has no build profile for it"
            case .incompatibleDockMethods:
                title = "This Dock does not match its build profile"
                reason = "the methods the payload calls have different signatures"
            case .failed:
                title = "The payload's hooks did not install"
                reason = "one of them failed validation, so none were installed"
            case .installed:
                title = "The payload has no hooks"
                reason = "this build of the payload declares none"
            }
            self.init(
                title: title,
                nextStep: "The Dock keeps opening the system's Apps: \(reason).",
                systemImageName: "xmark.octagon.fill",
                tint: .red
            )
        case .stalePayload:
            self.init(
                title: "Restart the Dock to update",
                nextStep: "The Dock still runs an older build of the payload; re-injecting does not replace it.",
                systemImageName: "clock.badge.exclamationmark.fill",
                tint: .orange
            )
        case .active:
            self.init(
                title: "Active",
                nextStep: "Launchpad replaces Apps in the Dock.",
                systemImageName: "checkmark.circle.fill",
                tint: .green
            )
        }
    }

    private init(title: String, nextStep: String, systemImageName: String, tint: Color) {
        self.title = title
        self.nextStep = nextStep
        self.systemImageName = systemImageName
        self.tint = tint
    }
}

/// The one thing to read first: is this working right now, and if not, what is the next step.
private struct ReadinessBanner: View {
    struct Action {
        let title: String
        let isEnabled: Bool
        let perform: () -> Void
    }

    let presentation: ReadinessPresentation
    let action: Action?

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: presentation.systemImageName)
                .font(.system(size: 28))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(presentation.tint)
                .frame(width: 34)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.headline)
                Text(presentation.nextStep)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)

            if let action {
                Button(action.title, action: action.perform)
                    .buttonStyle(.borderedProminent)
                    .tint(presentation.tint)
                    .disabled(!action.isEnabled)
            }
        }
        .padding(12)
        .background(presentation.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(presentation.tint.opacity(0.28), lineWidth: 1)
        )
        .animation(.default, value: presentation.title)
    }
}

// MARK: - Small pieces

/// A coloured dot next to a status string.
///
/// The dot carries the state at a glance; the text spells it out for anyone who cannot rely on the
/// colour alone, which is why both are always present.
private struct StatusIndicator: View {
    let text: String
    let tint: Color

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(tint)
                .frame(width: 8, height: 8)
            Text(text)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

/// A login item the user switched off, which only System Settings can switch back on.
private struct SystemSettingsWarning: View {
    let text: String
    let openLoginItems: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            Button("Open Login Items", action: openLoginItems)
                .controlSize(.small)
        }
    }
}

// MARK: - Menu bar

struct MenuBarContent: View {
    @Environment(PrivilegedDaemonController.self) private var daemonController
    @Environment(PayloadInjectionCoordinator.self) private var injectionCoordinator
    @Environment(ApplicationLaunchProgress.self) private var launchProgress
    @Environment(KillSwitchController.self) private var killSwitchController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(ReadinessPresentation(currentReadiness).title)

        Divider()

        // The only way back to the window: with no Dock icon once it is closed, and no app menu while
        // the app is an accessory, this item is what keeps the app reachable at all.
        Button("Open LaunchpadAwakener") {
            ApplicationActivationPolicyController.activateForWindowPresentation()
            openWindow(id: WindowIdentifier.main)
        }
        .keyboardShortcut(",")

        Divider()

        Button("Inject Now") {
            Task { await injectionCoordinator.injectIntoRunningTargets() }
        }
        .disabled(!daemonController.isEnabled || injectionCoordinator.isBusy)

        Button("Restart Dock") {
            injectionCoordinator.restartTargets()
        }
        .disabled(injectionCoordinator.isBusy)

        Toggle("Open the System's Apps Instead", isOn: killSwitchBinding)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }

    private var currentReadiness: ControlPanelReadiness {
        ControlPanelReadiness.evaluate(
            launchPhase: launchProgress.phase,
            daemonStatus: daemonController.registrationStatus,
            isKillSwitchEngaged: killSwitchController.isEngaged,
            isInjected: !injectionCoordinator.injectedProcessIdentifiers.isEmpty,
            residentPayloads: injectionCoordinator.residentPayloads
        )
    }

    private var killSwitchBinding: Binding<Bool> {
        Binding(
            get: { killSwitchController.isEngaged },
            set: { killSwitchController.setEngaged($0) }
        )
    }
}
