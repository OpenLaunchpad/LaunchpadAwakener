import Foundation
import ServiceManagement
import Testing
@testable import LaunchpadAwakenerAppCore

/// The control panel's status rows: what the Dock build row and the injection row say, and their dots.
@Suite("Status lines")
struct StatusLineTests {
    typealias ResidentPayload = PayloadInjectionCoordinator.ResidentPayload

    private static let imageUUID = UUID(uuidString: "6A1D3B2C-0000-4000-8000-000000000001")!

    private static func payload(
        processIdentifier: pid_t = 512,
        hookState: ResidentPayload.HookState = .installed(hookCount: 2),
        isStale: Bool = false,
        dockBundleVersion: String = "1985.6.3",
        dockSystemRelease: String = "27.2 (26B123)",
        dockGlobalsReachability: ResidentPayload.GlobalsReachability = .reachable
    ) -> ResidentPayload {
        ResidentPayload(
            hostProcessIdentifier: processIdentifier,
            hostProcessName: "Dock",
            imageUUID: imageUUID,
            isStale: isStale,
            hookState: hookState,
            dockBundleVersion: dockBundleVersion,
            dockSystemRelease: dockSystemRelease,
            dockGlobalsReachability: dockGlobalsReachability
        )
    }

    // MARK: - Dock build

    @Test("before the payload answers, the Dock build is unknown")
    func dockBuildBeforeInjection() {
        let line = StatusLine.dockBuild(reportedBy: nil)
        #expect(line == StatusLine(text: "Known once the Dock is injected", tint: .neutral, help: "The payload reports which Dock it is in once it is injected."))
    }

    @Test("a working Dock names the macOS it runs on, and the help gives its version")
    func supportedDockBuild() {
        let line = StatusLine.dockBuild(reportedBy: Self.payload())
        #expect(line.text == "macOS 27.2 (26B123) · supported")
        #expect(line.tint == .positive)
        #expect(line.help == "Dock 1985.6.3\nRunning on macOS 27.2 (26B123)")
    }

    /// Hooks installed but the globals out of reach is its own state: the Launchpad key is taken over,
    /// yet the replica cannot sit against the Dock. It has to read as a problem, and name what is
    /// missing.
    @Test("globals out of reach mark the row red and the help names what is missing")
    func dockWithUnreachableGlobals() {
        let line = StatusLine.dockBuild(
            reportedBy: Self.payload(dockGlobalsReachability: .unreachable(missingClassNames: ["DockBar", "DockGlobals"]))
        )
        #expect(line.text == "macOS 27.2 (26B123) · Launchpad's entry points are missing")
        #expect(line.tint == .critical)
        #expect(line.help == "Dock 1985.6.3\nRunning on macOS 27.2 (26B123)\nNot found in this Dock: DockBar, DockGlobals")
    }

    @Test("hooks that did not install mark the build red", arguments: [
        (ResidentPayload.HookState.incompatibleDockMethods, "Methods do not match"),
        (.failed(description: "Tile has no setter"), "Hooks failed to install"),
        (.installed(hookCount: 0), "No hooks declared"),
    ])
    func dockBuildWithoutHooks(hookState: ResidentPayload.HookState, text: String) {
        let line = StatusLine.dockBuild(reportedBy: Self.payload(hookState: hookState))
        #expect(line.text == text)
        #expect(line.tint == .critical)
    }

    @Test("a hook that failed validation says why in the help")
    func failedHookDescriptionIsInTheHelp() {
        let line = StatusLine.dockBuild(reportedBy: Self.payload(hookState: .failed(description: "Tile has no setter")))
        #expect(line.help.hasSuffix("\nTile has no setter"))
    }

    // MARK: - Injection

    @Test("no injected Dock is the orange 'Not injected'")
    func notInjected() {
        let line = StatusLine.injection(injectedProcessIdentifiers: [], residentPayloads: [])
        #expect(line.text == "Not injected")
        #expect(line.tint == .caution)
    }

    @Test("an injected Dock whose payload has not answered yet counts as working")
    func injectedWithoutAnswer() {
        let line = StatusLine.injection(injectedProcessIdentifiers: [512], residentPayloads: [])
        #expect(line == StatusLine(text: "Injected · process 512", tint: .positive))
    }

    @Test("an answering payload reports its build and how many hooks it installed")
    func injectedAndAnswering() {
        let line = StatusLine.injection(injectedProcessIdentifiers: [512], residentPayloads: [Self.payload()])
        #expect(line.text == "Process 512 · current build · 2 hooks")
        #expect(line.tint == .positive)
        #expect(line.help == "Dock 512: payload image 6A1D3B2C-0000-4000-8000-000000000001")
    }

    @Test("one hook is singular")
    func oneHook() {
        let line = StatusLine.injection(injectedProcessIdentifiers: [512], residentPayloads: [Self.payload(hookState: .installed(hookCount: 1))])
        #expect(line.text == "Process 512 · current build · 1 hook")
    }

    @Test("an older payload in the Dock is orange")
    func stalePayload() {
        let line = StatusLine.injection(injectedProcessIdentifiers: [512], residentPayloads: [Self.payload(isStale: true)])
        #expect(line.text == "Process 512 · older build · 2 hooks")
        #expect(line.tint == .caution)
    }

    @Test("a payload without hooks is red")
    func payloadWithoutHooks() {
        let line = StatusLine.injection(injectedProcessIdentifiers: [512], residentPayloads: [Self.payload(hookState: .incompatibleDockMethods)])
        #expect(line.text == "Process 512 · current build · no hooks")
        #expect(line.tint == .critical)
    }

    @Test("with two Docks, the row describes the lower process identifier")
    func lowestProcessIdentifierIsDescribed() {
        let line = StatusLine.injection(
            injectedProcessIdentifiers: [900, 512],
            residentPayloads: [Self.payload(processIdentifier: 900, isStale: true), Self.payload(processIdentifier: 512)]
        )
        #expect(line.text == "Process 512 · current build · 2 hooks")
    }

    // MARK: - Registration

    @Test("a login item's registration reads as a tint", arguments: [
        (SMAppService.Status.enabled, StatusTint.positive),
        (.requiresApproval, .caution),
        (.notFound, .critical),
        (.notRegistered, .neutral),
    ])
    func registrationTint(status: SMAppService.Status, tint: StatusTint) {
        #expect(StatusTint(status) == tint)
    }

    // MARK: - Input method helper

    private static let helperPath = "/Applications/LaunchpadAwakener.app/Contents/Library/LoginItems/LaunchpadAwakenerTextInput.app/Contents/MacOS/LaunchpadAwakenerTextInput"
    private static let helper = TextInputHelperProcess(processIdentifier: 4182, executablePath: helperPath, launchDate: Date(timeIntervalSince1970: 1_793_000_000))

    @Test("until the helper's agent is enabled, the row says what is wrong with the registration", arguments: [
        (SMAppService.Status.notRegistered, StatusLine(text: "Not registered — search and rename fields work without input methods.", tint: .neutral)),
        (.requiresApproval, StatusLine(text: "Turned off under System Settings › Login Items.", tint: .caution)),
        (.notFound, StatusLine(text: "Not found — the helper is missing from the app bundle.", tint: .critical)),
    ])
    func helperRegistration(status: SMAppService.Status, expected: StatusLine) {
        #expect(StatusLine.textInputHelper(registrationStatus: status, helperState: .current(Self.helper)) == expected)
    }

    @Test("an enabled helper that is not running starts with Launchpad")
    func helperNotRunning() {
        let line = StatusLine.textInputHelper(registrationStatus: .enabled, helperState: .notRunning)
        #expect(line.text == "Registered — starts when Launchpad opens.")
        #expect(line.tint == .positive)
    }

    @Test("the current helper is running, with its path in the help")
    func currentHelper() {
        let line = StatusLine.textInputHelper(registrationStatus: .enabled, helperState: .current(Self.helper))
        #expect(line == StatusLine(text: "Running · process 4182", tint: .positive, help: Self.helperPath))
    }

    @Test("an older build or another copy of the helper needs attention")
    func outdatedHelper() {
        let replaced = StatusLine.textInputHelper(registrationStatus: .enabled, helperState: .replacedSinceLaunch(Self.helper))
        let elsewhere = StatusLine.textInputHelper(registrationStatus: .enabled, helperState: .otherCopy(Self.helper))

        #expect(replaced.text == "An older build is running · process 4182")
        #expect(replaced.tint == .caution)
        #expect(elsewhere.text == "Another copy is running · process 4182")
        #expect(elsewhere.tint == .caution)
        #expect(elsewhere.help.contains(Self.helperPath))
    }
}
