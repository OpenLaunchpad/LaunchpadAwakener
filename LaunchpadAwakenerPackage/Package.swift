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
        // Linked by the text input helper, the LaunchAgent that hosts the springboard's text fields.
        .library(name: "LaunchpadAwakenerTextInputCore", targets: ["LaunchpadAwakenerTextInputCore"]),
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
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
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

        // The springboard itself — the layout library and macOS 15's interface — for whichever process
        // draws it: the Dock through the payload, or the standalone app. It reaches its host only
        // through `SpringboardHost`, and links neither AppKit nor anything Dock-specific, since the
        // payload carries it into the Dock.
        .target(
            name: "LaunchpadAwakenerSpringboardCore",
            dependencies: [
                "LaunchpadAwakenerHookKit",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ]
        ),

        // Payload side: what runs inside the host process, around the springboard — the Dock's side of
        // the host, the hooks and the entry. Keep this dependency list minimal — every library here is
        // mapped into a process that did not ask for it.
        .target(
            name: "LaunchpadAwakenerPayloadCore",
            dependencies: [
                "LaunchpadAwakenerShared",
                "LaunchpadAwakenerHookKit",
                "LaunchpadAwakenerSpringboardCore",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ]
        ),

        // Text input helper: hosts the search and rename fields in a window that never goes on screen, so
        // that input methods work in them; the payload shows the window in the Dock and forwards the keys.
        .target(
            name: "LaunchpadAwakenerTextInputCore",
            dependencies: [
                "LaunchpadAwakenerHookKit",
                "LaunchpadAwakenerShared",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ]
        ),

        // Shared test infrastructure: fixtures and helpers. Not a product, so nothing outside the
        // package can link it and it never ends up in a shipped binary.
        .target(
            name: "TestingSupport",
            dependencies: ["LaunchpadAwakenerSpringboardCore"],
            path: "Tests/TestingSupport"
        ),
        .testTarget(name: "TestingSupportTests", dependencies: ["TestingSupport"]),

        // The springboard's logic — the data layer, the interface's rules and its layers drawn off screen.
        // Nothing in these tests creates a window or touches the Dock.
        .testTarget(
            name: "LaunchpadAwakenerSpringboardCoreTests",
            dependencies: ["LaunchpadAwakenerSpringboardCore", "TestingSupport"],
            // macOS 15.5's own copy, which the exclusion list and default layout are checked against.
            resources: [.copy("Resources/LaunchPadLayout.plist")]
        ),

        // The Dock's side: the build profiles. Read from the Dock binaries' facts, never from a live Dock.
        .testTarget(
            name: "LaunchpadAwakenerPayloadCoreTests",
            dependencies: ["LaunchpadAwakenerPayloadCore"]
        ),
    ]
)
