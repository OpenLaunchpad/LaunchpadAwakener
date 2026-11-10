import Darwin

/// The System Integrity Protection configuration the running kernel enforces: the `CSR_ALLOW_*` flags of
/// xnu's `bsd/sys/csr.h`, each one a protection turned off.
///
/// Injecting the payload into the Dock needs SIP turned off. With it on, the Dock is shielded from other
/// processes and loads only libraries Apple signed, so this app guides the user to the standalone
/// Launchpad, which needs neither.
public struct SystemIntegrityProtectionConfiguration: OptionSet, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let allowUntrustedKernelExtensions = Self(rawValue: 1 << 0)
    public static let allowUnrestrictedFileSystem = Self(rawValue: 1 << 1)
    public static let allowTaskForProcessIdentifier = Self(rawValue: 1 << 2)
    public static let allowKernelDebugger = Self(rawValue: 1 << 3)
    public static let allowAppleInternal = Self(rawValue: 1 << 4)
    public static let allowUnrestrictedDTrace = Self(rawValue: 1 << 5)
    public static let allowUnrestrictedNVRAM = Self(rawValue: 1 << 6)
    public static let allowDeviceConfiguration = Self(rawValue: 1 << 7)
    public static let allowAnyRecoveryOperatingSystem = Self(rawValue: 1 << 8)
    public static let allowUnapprovedKernelExtensions = Self(rawValue: 1 << 9)
    public static let allowExecutablePolicyOverride = Self(rawValue: 1 << 10)
    public static let allowUnauthenticatedRoot = Self(rawValue: 1 << 11)
    public static let allowResearchGuests = Self(rawValue: 1 << 12)

    /// What `csrutil disable` writes (`CSR_DISABLE_FLAGS`) without Apple Internal, which the kernel clears on
    /// retail hardware.
    public static let disabledByCommand: Self = [
        .allowUntrustedKernelExtensions, .allowUnrestrictedFileSystem,
        .allowTaskForProcessIdentifier, .allowKernelDebugger,
        .allowUnrestrictedDTrace, .allowUnrestrictedNVRAM,
    ]

    /// Debug builds take this launch argument to behave as on a Mac with SIP on: the test machines all have
    /// it off.
    public static let assumeEnabledLaunchArgument = "--assume-system-integrity-protection-enabled"

    /// Every protection is on.
    public var isFullyEnabled: Bool {
        isEmpty
    }

    /// Turned off the way `csrutil disable` turns it off. A configuration that lifts only some protections,
    /// as `csrutil enable --without …` does, does not count.
    public var isDisabled: Bool {
        isSuperset(of: .disabledByCommand)
    }

    /// The configuration the running kernel enforces, or nil when it cannot be read.
    public static func active() -> Self? {
        // int csr_get_active_config(csr_config_t *config), exported by libsystem_kernel without an SDK header.
        typealias ActiveConfigurationFunction = @convention(c) (UnsafeMutablePointer<UInt32>) -> Int32
        let defaultHandle = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        guard let symbol = dlsym(defaultHandle, "csr_get_active_config") else { return nil }
        let activeConfigurationFunction = unsafeBitCast(symbol, to: ActiveConfigurationFunction.self)
        var rawConfiguration: UInt32 = 0
        guard activeConfigurationFunction(&rawConfiguration) == 0 else { return nil }
        return Self(rawValue: rawConfiguration)
    }

    /// Whether SIP keeps this app from injecting into the Dock: the active configuration is not
    /// `csrutil disable`'s. One that cannot be read does not: the launch then tries to inject as it always
    /// has, and the banner reports what goes wrong. Debug builds also give in to
    /// ``assumeEnabledLaunchArgument``.
    public static func blocksInjection(active activeConfiguration: Self?, launchArguments: [String]) -> Bool {
        #if DEBUG
        if launchArguments.contains(assumeEnabledLaunchArgument) {
            return true
        }
        #endif
        guard let activeConfiguration else { return false }
        return !activeConfiguration.isDisabled
    }
}
