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
        dockBundleVersion: String? = "1985.6.3",
        dockSystemReleases: [String] = ["27.1 (26B82)", "27.2 (26B123)"]
    ) -> ResidentPayload {
        ResidentPayload(
            hostProcessIdentifier: processIdentifier,
            hostProcessName: "Dock",
            imageUUID: imageUUID,
            isStale: isStale,
            hookState: hookState,
            dockBundleVersion: dockBundleVersion,
            dockSystemReleases: dockSystemReleases
        )
    }

    // MARK: - Dock build

    @Test("before the payload answers, the Dock build is unknown")
    func dockBuildBeforeInjection() {
        let line = StatusLine.dockBuild(reportedBy: nil)
        #expect(line == StatusLine(text: "Known once the Dock is injected", tint: .neutral, help: "The payload reports the Dock build once it is in the Dock."))
    }

    @Test("a supported build names the newest macOS that ships it, and the help lists them all")
    func supportedDockBuild() {
        let line = StatusLine.dockBuild(reportedBy: Self.payload())
        #expect(line.text == "macOS 27.2 (26B123) · supported")
        #expect(line.tint == .positive)
        #expect(line.help == "Dock 1985.6.3\nShips with macOS 27.1 (26B82), 27.2 (26B123)")
    }

    @Test("a build the payload has no profile for is not supported, and the help gives its executable UUID")
    func unknownDockBuild() {
        let line = StatusLine.dockBuild(reportedBy: Self.payload(hookState: .unknownDockBuild(executableUUID: "0F1E"), dockBundleVersion: nil, dockSystemReleases: []))
        #expect(line.text == "Unknown build — not supported")
        #expect(line.tint == .critical)
        #expect(line.help == "Executable UUID 0F1E")
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
        let line = StatusLine.injection(injectedProcessIdentifiers: [512], residentPayloads: [Self.payload(hookState: .unknownDockBuild(executableUUID: "0F1E"))])
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
}
