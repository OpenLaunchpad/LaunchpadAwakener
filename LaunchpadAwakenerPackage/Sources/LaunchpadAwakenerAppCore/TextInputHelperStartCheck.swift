import Darwin
import Foundation
import LaunchpadAwakenerShared
import XPC

/// Whether launchd starts the input method helper when something connects to it, and the repair when it
/// does not.
///
/// `SMAppService` can report the agent enabled while launchd cannot start it: the login item record and
/// launchd's job have been seen to part. On one Mac the job pointed at a record that no longer existed and
/// failed every ten seconds; on another there was no job at all. Nothing tells the app, and the springboard
/// just finds no helper. So the app connects once, as the payload does, and looks for the process launchd
/// starts. The helper takes only the Dock and ends the session at once; the process is what tells.
///
/// Unregistering and registering the agent again hands launchd a new job. That brings back a helper whose
/// job was missing. It does not bring back one whose login item record points at a copy of the app that is
/// gone: the record is kept by the agent's label, shared by every copy that registered it, and stays with
/// the copy that registered it first. Only logging out and back in may help then, which the control panel
/// says.
@MainActor
struct TextInputHelperStartCheck {
    /// What the check found.
    enum Outcome: Equatable, Sendable {
        /// launchd started the helper, or one was running already.
        case starts
        /// launchd did not start it until the agent was registered again.
        case startsAfterRegisteringAgain
        /// launchd did not start it, even with the agent registered again.
        case doesNotStart
    }

    /// Opens a connection to the helper and sends it something, which has launchd start it. Returns what
    /// closes the connection, or nil when launchd has no such service.
    var connect: () -> (() -> Void)?
    /// The process identifiers of the helpers running now.
    var runningHelpers: () -> [pid_t]
    /// How long to wait for the helper: past launchd's ten seconds between starts of a job whose process
    /// was just ended, as ``TextInputAgentController/restartHelperIfReplaced()`` may have done.
    var deadline: Duration = .seconds(15)
    var pollingInterval: Duration = .milliseconds(250)

    /// Checks that the helper starts, and when it does not, has `registerAgain` hand launchd a new job and
    /// checks once more.
    ///
    /// - Parameter endedProcessIdentifier: A helper just ended, which does not count while it goes away.
    func run(besides endedProcessIdentifier: pid_t?, registerAgain: () async -> Void) async -> Outcome {
        if await helperStarts(besides: endedProcessIdentifier) {
            return .starts
        }
        await registerAgain()
        return await helperStarts(besides: endedProcessIdentifier) ? .startsAfterRegisteringAgain : .doesNotStart
    }

    /// Whether a helper other than `endedProcessIdentifier` runs, once connected to, within the deadline.
    func helperStarts(besides endedProcessIdentifier: pid_t?) async -> Bool {
        guard let close = connect() else { return false }
        defer { close() }
        let clock = ContinuousClock()
        let end = clock.now.advanced(by: deadline)
        while true {
            if runningHelpers().contains(where: { $0 != endedProcessIdentifier }) {
                return true
            }
            guard clock.now < end else { return false }
            try? await Task.sleep(for: pollingInterval)
        }
    }
}

extension TextInputHelperStartCheck {
    /// Connects to this build's helper and looks for it in the process table.
    static func live() -> TextInputHelperStartCheck {
        TextInputHelperStartCheck(
            connect: {
                guard let session = try? XPCSession(machService: TextInputServiceIdentity.machServiceName) else { return nil }
                // A message has launchd start the helper. It refuses the app; were it ever to take it,
                // `end` does nothing where no field is hosted.
                try? session.send(TextInputRequest.end)
                return {
                    session.cancel(reason: "The app checked that launchd starts the helper")
                }
            },
            runningHelpers: {
                TextInputHelperState.runningHelperProcesses(
                    bundleIdentifier: TextInputServiceIdentity.machServiceName,
                    executableName: (TextInputServiceIdentity.helperBundleProgram as NSString).lastPathComponent
                ).map(\.processIdentifier)
            }
        )
    }
}
