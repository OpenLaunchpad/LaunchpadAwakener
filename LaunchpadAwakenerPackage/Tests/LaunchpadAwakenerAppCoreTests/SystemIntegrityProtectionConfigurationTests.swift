import Testing
@testable import LaunchpadAwakenerAppCore

/// Which System Integrity Protection configurations let the app inject into the Dock. The flag values are
/// xnu's `bsd/sys/csr.h`.
@Suite("System Integrity Protection")
struct SystemIntegrityProtectionConfigurationTests {
    private typealias Configuration = SystemIntegrityProtectionConfiguration

    @Test("csrutil disable turns SIP off, with or without Apple Internal")
    func disabledByCommand() {
        // `CSR_DISABLE_FLAGS` is 0x7F; a retail Mac clears Apple Internal and runs with 0x6F.
        #expect(Configuration(rawValue: 0x7F).isDisabled)
        #expect(Configuration(rawValue: 0x6F).isDisabled)
        #expect(Configuration(rawValue: 0x6F).union(.allowUnauthenticatedRoot).isDisabled)
    }

    @Test("SIP fully on, or lifted only in part, is not off")
    func notDisabled() {
        #expect(Configuration(rawValue: 0).isFullyEnabled)
        #expect(!Configuration(rawValue: 0).isDisabled)
        #expect(!Configuration([.allowTaskForProcessIdentifier, .allowKernelDebugger]).isDisabled)
        #expect(!Configuration(rawValue: 0x6F).subtracting(.allowUnrestrictedFileSystem).isDisabled)
    }

    @Test("SIP that is not off blocks injection; a configuration that cannot be read does not")
    func blocksInjection() {
        #expect(Configuration.blocksInjection(active: [], launchArguments: []))
        #expect(Configuration.blocksInjection(active: [.allowTaskForProcessIdentifier], launchArguments: []))
        #expect(!Configuration.blocksInjection(active: .disabledByCommand, launchArguments: []))
        #expect(!Configuration.blocksInjection(active: nil, launchArguments: []))
    }

    @Test("a debug build behaves as with SIP on when launched with the argument, whatever the Mac's SIP")
    func assumedEnabled() {
        let launchArguments = ["/Applications/LaunchpadAwakener.app/Contents/MacOS/LaunchpadAwakener", Configuration.assumeEnabledLaunchArgument]
        #expect(Configuration.blocksInjection(active: .disabledByCommand, launchArguments: launchArguments))
        #expect(Configuration.blocksInjection(active: nil, launchArguments: launchArguments))
    }

    @Test("the running kernel's configuration can be read")
    func activeConfigurationIsReadable() {
        #expect(Configuration.active() != nil)
    }
}
