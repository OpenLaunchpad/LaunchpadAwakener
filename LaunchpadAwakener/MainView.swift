import SwiftUI
import AppKit
import LaunchpadAwakenerAppCore

struct MainView: View {
    @Environment(PrivilegedDaemonController.self) private var daemonController
    @Environment(PayloadInjectionCoordinator.self) private var injectionCoordinator

    var body: some View {
        Form {
            Section("Privileged Daemon") {
                LabeledContent("Status") {
                    Text(daemonController.statusMessage)
                        .foregroundStyle(daemonController.isEnabled ? .primary : .secondary)
                }

                HStack {
                    Button("Install") {
                        Task { await daemonController.install() }
                    }
                    .disabled(daemonController.isEnabled || daemonController.isPerformingRegistrationChange)

                    Button("Uninstall") {
                        Task { await daemonController.uninstall() }
                    }
                    .disabled(!daemonController.isEnabled || daemonController.isPerformingRegistrationChange)

                    if daemonController.isPerformingRegistrationChange {
                        ProgressView().controlSize(.small)
                    }
                }
            }

            Section("Injection") {
                LabeledContent("Payload") {
                    Text(injectionCoordinator.isPayloadStaged ? "Staged" : "Not staged")
                        .foregroundStyle(.secondary)
                }

                LabeledContent("Injected processes") {
                    Text(injectedProcessesDescription)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }

                Toggle("Inject automatically", isOn: automaticInjectionBinding)
                    .disabled(!daemonController.isEnabled)

                HStack {
                    Button("Inject now") {
                        Task { await injectionCoordinator.injectIntoRunningTargets() }
                    }
                    .disabled(!daemonController.isEnabled || injectionCoordinator.isInjecting)

                    if injectionCoordinator.isInjecting {
                        ProgressView().controlSize(.small)
                    }
                }

                // Say what happened. Injection can legitimately do nothing — no target running, or
                // everything already injected — and a button that silently does nothing is
                // indistinguishable from one that is broken.
                if let outcome = injectionCoordinator.lastInjectionOutcome {
                    Text(outcome.summary)
                        .font(.caption)
                        .foregroundStyle(outcome.isFailure ? .red : .secondary)
                        .textSelection(.enabled)
                }
            }

            if let lastErrorDescription = injectionCoordinator.lastErrorDescription {
                Section("Last Error") {
                    Text(lastErrorDescription)
                        .foregroundStyle(.red)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .onAppear { daemonController.refreshStatus() }
    }

    private var injectedProcessesDescription: String {
        let identifiers = injectionCoordinator.injectedProcessIdentifiers
        guard !identifiers.isEmpty else { return "None" }
        return identifiers.sorted().map(String.init).joined(separator: ", ")
    }

    private var automaticInjectionBinding: Binding<Bool> {
        Binding(
            get: { injectionCoordinator.isAutomaticInjectionEnabled },
            set: { isEnabled in
                if isEnabled {
                    injectionCoordinator.startAutomaticInjection()
                } else {
                    injectionCoordinator.stopAutomaticInjection()
                }
                // Launching at login only exists to inject again after login.
                LaunchAtLogin.setEnabled(isEnabled)
            }
        )
    }
}

struct MenuBarContent: View {
    @Environment(PrivilegedDaemonController.self) private var daemonController
    @Environment(PayloadInjectionCoordinator.self) private var injectionCoordinator
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(daemonController.statusMessage)

        if let lastErrorDescription = injectionCoordinator.lastErrorDescription {
            Text(lastErrorDescription)
        }

        Divider()

        Button("Show Window") {
            openWindow(id: "main")
            NSApplication.shared.activate()
        }

        Button("Inject Now") {
            Task { await injectionCoordinator.injectIntoRunningTargets() }
        }
        .disabled(!daemonController.isEnabled)

        Divider()

        Button("Quit") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
