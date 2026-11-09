import SwiftUI
import AppKit
import LaunchpadAwakenerAppCore

struct MainView: View {
    @Environment(PrivilegedDaemonController.self) private var daemonController
    @Environment(PayloadInjectionCoordinator.self) private var injectionCoordinator
    @Environment(LaunchAtLoginController.self) private var launchAtLoginController
    @Environment(ApplicationLaunchProgress.self) private var launchProgress
    @Environment(TextInputAgentController.self) private var textInputAgentController
    @Environment(KillSwitchController.self) private var killSwitchController

    /// How often the window re-checks what it is displaying while it is open.
    ///
    /// Frequent enough that restarting the Dock looks immediate, infrequent enough to be unnoticeable:
    /// one `kill(pid, 0)` per known Dock, one status request per open payload channel, and a few
    /// `SMAppService` and file-system reads.
    private static let stateRefreshInterval = Duration.seconds(3)

    var body: some View {
        VStack(spacing: 0) {
            ReadinessBanner(presentation: ReadinessPresentation(currentReadiness), action: bannerAction)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)

            Divider()

            Form {
                startupSection
                launchpadSection
                daemonSection
                injectionSection
                errorSection
            }
            .formStyle(.grouped)
            // A grouped form wraps its content in a scroll view that expands to whatever height it is
            // handed, so the window would open at some default height with the rest scrolled away.
            // Fixing the vertical size makes the form report its own height, which
            // `.windowResizability(.contentSize)` then adopts. Scrolling stays enabled so that on a
            // short display the bottom is still reachable.
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 560)
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

    // MARK: - Readiness

    private var currentReadiness: ControlPanelReadiness {
        ControlPanelReadiness.evaluate(
            launchPhase: launchProgress.phase,
            daemonStatus: daemonController.registrationStatus,
            isKillSwitchEngaged: killSwitchController.isEngaged,
            isInjected: !injectionCoordinator.injectedProcessIdentifiers.isEmpty,
            residentPayloads: injectionCoordinator.residentPayloads
        )
    }

    /// The one-click next step the banner offers, where there is one.
    private var bannerAction: ReadinessBanner.Action? {
        switch currentReadiness {
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

    // MARK: - Startup

    /// First, because it is the first thing anyone wants after getting the tool working once: not
    /// having to set it up again after the next restart.
    private var startupSection: some View {
        Section {
            Toggle("Launch at login", isOn: launchAtLoginBinding)

            if launchAtLoginController.isDisabledInSystemSettings {
                SystemSettingsWarning(
                    text: "Turned off under System Settings › Login Items. The app cannot switch it back on itself.",
                    openLoginItems: launchAtLoginController.openLoginItemsSettings
                )
            }

            Text("When on, the app starts with your Mac and stays in the menu bar without opening this window, injecting the Dock as it goes. Open the window again from the menu bar icon.")
                .font(.caption)
                .foregroundStyle(.secondary)

            #if DEBUG
            // The login item records this build product's path. Nothing warns the user when that
            // path stops existing — login simply fails to launch anything, silently.
            Text("Debug build: the login item points at this build's path. Turn it off before deleting the build, or login will try to launch a binary that is no longer there. Debug and release builds share one login item — whichever registered last wins.")
                .font(.caption)
                .foregroundStyle(.orange)
            #endif
        } header: {
            Label("Startup", systemImage: "power")
        }
    }

    // MARK: - Launchpad

    private var launchpadSection: some View {
        Section {
            Toggle(isOn: killSwitchBinding) {
                Text("Open the system's Apps instead")
                Text("Every way of opening Apps goes to the system's Apps while this is on. Takes effect at once, and switches itself off when the Mac restarts.")
            }

            LabeledContent("Dock build") {
                StatusIndicator(text: dockBuildDescription, tint: dockBuildTint)
                    .help(dockBuildHelp)
            }

            LabeledContent("Input method helper") {
                HStack(spacing: 10) {
                    StatusIndicator(text: textInputAgentController.statusMessage, tint: textInputAgentTint)
                    if textInputAgentController.registrationStatus == .notRegistered {
                        Button("Register") {
                            textInputAgentController.registerIfNeeded()
                        }
                        .controlSize(.small)
                    }
                }
            }

            if textInputAgentController.isDisabledInSystemSettings {
                SystemSettingsWarning(
                    text: "The input method helper is turned off under System Settings › Login Items, so search and rename fields cannot use input methods.",
                    openLoginItems: textInputAgentController.openLoginItemsSettings
                )
            }

            Text("The input method helper hosts the search and rename fields so that input methods such as Pinyin work in them.")
                .font(.caption)
                .foregroundStyle(.secondary)
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
            return "Reported once the Dock is injected"
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
            return "Known build, but its methods do not match"
        case .failed:
            return "Hooks failed to install"
        }
    }

    private var dockBuildTint: Color {
        guard let payload = reportingPayload else { return .secondary }
        return payload.areHooksInstalled ? .green : .red
    }

    private var dockBuildHelp: String {
        guard let payload = reportingPayload else { return "" }
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

    private var textInputAgentTint: Color {
        switch textInputAgentController.registrationStatus {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notFound: return .red
        default: return .secondary
        }
    }

    // MARK: - Daemon

    private var daemonSection: some View {
        Section {
            LabeledContent("Status") {
                StatusIndicator(text: daemonController.statusMessage, tint: daemonStatusTint)
            }

            HStack {
                Button("Install") {
                    Task { await daemonController.install() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(daemonController.isEnabled || daemonController.isPerformingRegistrationChange)

                Button("Uninstall") {
                    Task { await daemonController.uninstall() }
                }
                .tint(.red)
                .disabled(!daemonController.isEnabled || daemonController.isPerformingRegistrationChange)

                if daemonController.isPerformingRegistrationChange {
                    ProgressView().controlSize(.small)
                }
            }

            Text("The daemon injects the payload into the Dock, which needs root. System Settings asks you to approve it once, under General › Login Items.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Privileged Daemon", systemImage: "lock.shield.fill")
        }
    }

    private var daemonStatusTint: Color {
        switch daemonController.registrationStatus {
        case .enabled: return .green
        case .requiresApproval: return .orange
        case .notFound: return .red
        default: return .secondary
        }
    }

    // MARK: - Injection

    private var injectionSection: some View {
        Section {
            LabeledContent("Injected") {
                StatusIndicator(text: injectedDescription, tint: isInjected ? .green : .orange)
            }

            // What the payload says about itself, rather than what this app remembers doing. The
            // difference matters after a relaunch, when the app remembers nothing.
            ForEach(injectionCoordinator.residentPayloads) { payload in
                LabeledContent("Payload in \(payload.hostProcessName)") {
                    StatusIndicator(text: describe(payload), tint: tint(of: payload))
                        .help("Payload image \(payload.imageUUID.uuidString)")
                }
            }

            Toggle("Re-inject automatically after the Dock restarts", isOn: automaticInjectionBinding)
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

                if injectionCoordinator.isBusy {
                    ProgressView().controlSize(.small)
                }

                if injectionCoordinator.isWaitingForTargetRestart {
                    Text("Waiting for the Dock to come back…")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            // Injection can legitimately do nothing — no Dock running, or already injected. Saying so
            // is what separates a normal no-op from a broken button.
            if let report = injectionCoordinator.lastInjectionReport {
                Label(report.summary, systemImage: report.isFailure ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.callout)
                    .foregroundStyle(report.isFailure ? Color.red : Color.green)
                    .textSelection(.enabled)
            }

            // A payload cannot be unloaded, so re-injecting a rebuilt one does nothing at all. Saying
            // so is the only way out of concluding that the change itself did not work.
            if injectionCoordinator.hasStalePayload {
                CalloutLabel(
                    text: "The Dock still runs an older build of the payload. Restart the Dock to load this one — re-injecting will not replace it.",
                    systemImage: "clock.badge.exclamationmark.fill"
                )
            }

            // The button re-injects on its own, so what is left is a Dock that goes away without this
            // app asking: crashed, killed from a terminal, or replaced by logging back in.
            if !injectionCoordinator.isAutomaticInjectionEnabled {
                CalloutLabel(
                    text: "With this off, a Dock that restarts on its own — crashed, killed from a terminal, or after logging back in — comes back with the system's Apps. Restarting it from here still re-injects.",
                    systemImage: "exclamationmark.triangle.fill"
                )
            }

            Text("Restarting the Dock is only needed after installing a new build of LaunchpadAwakener: the payload already in the Dock cannot be replaced while it runs.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Label("Dock Injection", systemImage: "arrow.down.circle.fill")
        }
    }

    private var isInjected: Bool { !injectionCoordinator.injectedProcessIdentifiers.isEmpty }

    private var injectedDescription: String {
        let processIdentifiers = injectionCoordinator.injectedProcessIdentifiers.sorted()
        guard !processIdentifiers.isEmpty else { return "No" }
        return "Yes — \(processIdentifiers.map(String.init).joined(separator: ", "))"
    }

    private func describe(_ payload: PayloadInjectionCoordinator.ResidentPayload) -> String {
        let buildDescription = payload.isStale ? "older build" : "current build"
        switch payload.hookState {
        case .installed(let hookCount) where hookCount > 0:
            return "\(buildDescription) · \(hookCount) hook\(hookCount == 1 ? "" : "s")"
        case .installed, .unknownDockBuild, .incompatibleDockMethods, .failed:
            return "\(buildDescription) · attached but inert — no hooks installed"
        }
    }

    private func tint(of payload: PayloadInjectionCoordinator.ResidentPayload) -> Color {
        guard payload.areHooksInstalled else { return .red }
        return payload.isStale ? .orange : .green
    }

    // MARK: - Errors

    /// Every outstanding error, not just the first one found.
    ///
    /// Showing one and swallowing the rest hides exactly the case worth seeing: two things failing at
    /// once, where fixing the visible half changes nothing and there is no sign of the other.
    private var errorSection: some View {
        Group {
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

    // MARK: - Bindings

    private var automaticInjectionBinding: Binding<Bool> {
        Binding(
            get: { injectionCoordinator.isAutomaticInjectionEnabled },
            set: { injectionCoordinator.setAutomaticInjectionEnabled($0) }
        )
    }

    private var launchAtLoginBinding: Binding<Bool> {
        Binding(
            get: { launchAtLoginController.isEnabled },
            set: { launchAtLoginController.setEnabled($0) }
        )
    }

    private var killSwitchBinding: Binding<Bool> {
        Binding(
            get: { killSwitchController.isEngaged },
            set: { killSwitchController.setEngaged($0) }
        )
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
                nextStep: "The Dock opens the system's Apps until “Open the system's Apps instead” is switched off.",
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
                nextStep: "The Dock still runs an older build of the payload. Re-injecting does not replace it; restarting the Dock does.",
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
        .padding(14)
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
        }
    }
}

/// An orange line explaining something the user should know before relying on the switch above it.
private struct CalloutLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// A login item the user switched off, which only System Settings can switch back on.
private struct SystemSettingsWarning: View {
    let text: String
    let openLoginItems: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            CalloutLabel(text: text, systemImage: "exclamationmark.triangle.fill")
            Spacer(minLength: 0)
            Button("Open Login Items", action: openLoginItems)
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
