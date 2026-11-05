// swift-tools-version: 6.2

import PackageDescription

// Every line of real code lives here; the Xcode project holds only the four thin binary shells
// (app, daemon, payload, and the payload's Objective-C entry file). Modules are split by which
// binary links them, because the app must not pull in the daemon's privileged dependencies and the
// payload must stay as small as possible — it gets mapped into someone else's process.
let package = Package(
    name: "LaunchpadAwakenerPackage",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        // Linked by the app target.
        .library(name: "LaunchpadAwakenerAppCore", targets: ["LaunchpadAwakenerAppCore"]),
        // Linked by the privileged daemon target.
        .library(name: "LaunchpadAwakenerDaemonCore", targets: ["LaunchpadAwakenerDaemonCore"]),
        // Linked by the injected payload target.
        .library(name: "LaunchpadAwakenerPayloadCore", targets: ["LaunchpadAwakenerPayloadCore"]),
        // Standalone so it can be reused or tested without dragging in the payload's specifics.
        .library(name: "LaunchpadAwakenerHookKit", targets: ["LaunchpadAwakenerHookKit"]),
        .library(name: "LaunchpadAwakenerShared", targets: ["LaunchpadAwakenerShared"]),
    ],
    dependencies: [
        // Privileged-helper plumbing: SMAppService installation, typed XPC request/response, and the
        // two injection paths (dlopen and mach_vm_remap).
        //
        // Pinned exactly, as DockIconOverride does: `from:` resolves forward to 0.4.0, which no
        // longer has the `InjectApplicationViaRemapRequest` the app core still sends.
        //
        // To develop against a local checkout, replace this line with:
        //   .package(path: "../../swift-helper-service")
        .package(url: "https://github.com/Mx-Iris/swift-helper-service", exact: "0.1.4"),
        // `@Loggable` and `#log` for the payload's logging. Already in the graph through
        // swift-helper-service; named here because the payload uses it directly.
        .package(url: "https://github.com/Mx-Iris/FrameworkToolbox", from: "0.17.0"),
    ],
    targets: [
        // Names, versions and paths shared by all three binaries. No dependencies on purpose —
        // anything heavier would end up inside the payload.
        .target(name: "LaunchpadAwakenerShared"),

        // Objective-C method replacement with signature validation and atomic batch installation.
        // Depends on nothing but the Objective-C runtime.
        .target(name: "LaunchpadAwakenerHookKit"),

        // App side: daemon lifecycle, target-process monitoring, injection orchestration.
        .target(
            name: "LaunchpadAwakenerAppCore",
            dependencies: [
                "LaunchpadAwakenerShared",
                .product(name: "HelperClient", package: "swift-helper-service"),
                .product(name: "HelperCommunication", package: "swift-helper-service"),
                // Interface-only: the app sends these requests but must not link the
                // implementations, which pull in MachInjector and only make sense as root.
                .product(name: "InjectionServiceInterface", package: "swift-helper-service"),
                .product(name: "FilesServiceInterface", package: "swift-helper-service"),
            ]
        ),

        // Daemon side: hosts the service implementations that need root.
        .target(
            name: "LaunchpadAwakenerDaemonCore",
            dependencies: [
                "LaunchpadAwakenerShared",
                .product(name: "HelperServer", package: "swift-helper-service"),
                .product(name: "HelperService", package: "swift-helper-service"),
                .product(name: "HelperCommunication", package: "swift-helper-service"),
                .product(name: "InjectionServiceImplementation", package: "swift-helper-service"),
                .product(name: "FilesServiceImplementation", package: "swift-helper-service"),
            ]
        ),

        // Payload side: what runs inside the host process. Keep this dependency list minimal —
        // every library here is mapped into a process that did not ask for it.
        .target(
            name: "LaunchpadAwakenerPayloadCore",
            dependencies: [
                "LaunchpadAwakenerShared",
                "LaunchpadAwakenerHookKit",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ]
        ),
    ]
)
