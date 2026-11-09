// swift-tools-version: 6.2

import PackageDescription

// Every line of real code lives here; the Xcode project holds only the thin binary shells (app,
// daemon, payload and the payload's Objective-C entry file, text input helper, standalone app).
// Modules are split by which binary links them, because the app must not pull in the daemon's
// privileged dependencies and the payload must stay as small as possible — it gets mapped into
// someone else's process. The springboard itself is one module both of its hosts link: the payload
// in the Dock and the standalone app.

/// Links private frameworks whose classes `LaunchpadAwakenerPrivateInterfaces` declares. Their stubs are in
/// the SDK's `System/Library/PrivateFrameworks`, which is not searched by default; the linker resolves the
/// absolute path below inside the SDK. Every process that links these has the frameworks loaded already.
func linkingPrivateFrameworks(_ frameworkNames: [String]) -> [LinkerSetting] {
    [.unsafeFlags(["-F/System/Library/PrivateFrameworks"])] + frameworkNames.map { .linkedFramework($0) }
}

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
        // Linked by the standalone app, which draws the springboard in a window of its own.
        .library(name: "LaunchpadAwakenerStandaloneCore", targets: ["LaunchpadAwakenerStandaloneCore"]),
        .library(name: "LaunchpadAwakenerShared", targets: ["LaunchpadAwakenerShared"]),
        // The request types the app and the injected payload speak to each other.
        .library(name: "LaunchpadAwakenerPayloadInterface", targets: ["LaunchpadAwakenerPayloadInterface"]),
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
        // `@Loggable` and `#log` for the payload's logging, and `ObjCRuntimeToolbox` for every call into
        // and hook on a class that has no header. Already in the graph through swift-helper-service;
        // named here because the payload uses it directly.
        //
        // 0.17.2 is the floor: it declares `ObjCRuntimeToolbox-Static` `.static`, so a build that
        // would link it into two images fails instead of quietly turning it into an @rpath dylib the
        // payload could not carry into the Dock, and its `DynamicObject` hands an initialiser its
        // receiver, so `[[Class alloc] init…]` returning nil no longer over-releases inside the Dock.
        .package(url: "https://github.com/Mx-Iris/FrameworkToolbox", from: "0.17.2"),
        // The standalone app's global shortcut: a recorder for its settings and a Carbon hot key, which
        // needs no permission. Only the standalone module links it.
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "3.1.0"),
    ],
    targets: [
        // Names, versions and paths shared by all three binaries. No dependencies on purpose —
        // anything heavier would end up inside the payload.
        .target(name: "LaunchpadAwakenerShared"),

        // Declarations of the private Objective-C classes of IconServices, IconFoundation, SkyLight and
        // QuartzCore that the springboard and its hosts call directly — exported classes, declared as macOS
        // 26.6.2 and 27.2 implement them. No AppKit, since the payload imports this.
        .target(name: "LaunchpadAwakenerPrivateInterfaces"),

        // AppKit's private methods the text input helper calls, kept apart so that importing the module
        // above never brings AppKit into the payload.
        .target(
            name: "LaunchpadAwakenerAppKitPrivateInterfaces",
            dependencies: ["LaunchpadAwakenerPrivateInterfaces"]
        ),

        // What the app and the payload say to each other over their direct XPC channel. Both sides
        // link this, so it holds request types and nothing else.
        .target(
            name: "LaunchpadAwakenerPayloadInterface",
            dependencies: [
                .product(name: "HelperCommunication", package: "swift-helper-service"),
            ]
        ),

        // App side: daemon lifecycle, target-process monitoring, injection orchestration.
        .target(
            name: "LaunchpadAwakenerAppCore",
            dependencies: [
                "LaunchpadAwakenerShared",
                "LaunchpadAwakenerPayloadInterface",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
                .product(name: "HelperClient", package: "swift-helper-service"),
                .product(name: "HelperCommunication", package: "swift-helper-service"),
                .product(name: "HelperPeer", package: "swift-helper-service"),
                // Interface-only: the app sends these requests but must not link the
                // implementations, which pull in MachInjector and only make sense as root.
                .product(name: "InjectionServiceInterface", package: "swift-helper-service"),
                .product(name: "FilesServiceInterface", package: "swift-helper-service"),
                .product(name: "InjectedEndpointRegistryServiceInterface", package: "swift-helper-service"),
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
                // Remembers where each injected payload can be reached, so a relaunched app can find
                // the payloads that are still resident.
                .product(name: "InjectedEndpointRegistryServiceImplementation", package: "swift-helper-service"),
            ]
        ),

        // The springboard itself — the layout library and macOS 15's interface — for whichever process
        // draws it: the Dock through the payload, or the standalone app. It reaches its host only
        // through `SpringboardHost`, and links neither AppKit nor anything Dock-specific, since the
        // payload carries it into the Dock.
        .target(
            name: "LaunchpadAwakenerSpringboardCore",
            dependencies: [
                // For the kill switch's path, which the app's window also toggles.
                "LaunchpadAwakenerShared",
                "LaunchpadAwakenerPrivateInterfaces",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
            ],
            linkerSettings: linkingPrivateFrameworks(["IconServices"])
        ),

        // Payload side: what runs inside the host process, around the springboard — the Dock's side of
        // the host, the hooks and the entry. Keep this dependency list minimal — every library here is
        // mapped into a process that did not ask for it. `HelperPeer` and `HelperClient` are here
        // because the payload publishes an endpoint the app can reach it on; without that the app
        // cannot tell an injected Dock from an uninjected one, or say that the hooks did not go in.
        //
        // `ObjCRuntimeToolbox-Static` for the hooks and every call into the Dock's own classes, which no
        // framework exports: rather than the `.dynamic` product, because the payload has to be
        // self-contained, with nothing to find through @rpath inside the Dock. Its state is then per image,
        // which is fine as long as the Dock holds one copy.
        .target(
            name: "LaunchpadAwakenerPayloadCore",
            dependencies: [
                "LaunchpadAwakenerShared",
                "LaunchpadAwakenerPrivateInterfaces",
                "LaunchpadAwakenerSpringboardCore",
                "LaunchpadAwakenerPayloadInterface",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
                .product(name: "ObjCRuntimeToolbox-Static", package: "FrameworkToolbox"),
                .product(name: "HelperClient", package: "swift-helper-service"),
                .product(name: "HelperPeer", package: "swift-helper-service"),
                .product(name: "InjectedEndpointRegistryServiceInterface", package: "swift-helper-service"),
            ]
        ),

        // Standalone app side: the springboard's other host — a window of its own over the whole screen,
        // the replicas of the Dock's layer classes, the wallpaper from its file. Links AppKit.
        .target(
            name: "LaunchpadAwakenerStandaloneCore",
            dependencies: [
                "LaunchpadAwakenerPrivateInterfaces",
                "LaunchpadAwakenerSpringboardCore",
                .product(name: "OSToolbox", package: "FrameworkToolbox"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
            ],
            linkerSettings: linkingPrivateFrameworks(["IconServices", "IconFoundation", "SkyLight"])
        ),

        // Text input helper: hosts the search and rename fields in a window that never goes on screen, so
        // that input methods work in them; the payload shows the window in the Dock and forwards the keys.
        .target(
            name: "LaunchpadAwakenerTextInputCore",
            dependencies: [
                "LaunchpadAwakenerAppKitPrivateInterfaces",
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

        // The standalone host's own rules: which picture of a dynamic wallpaper shows, the icon style
        // table, the room left for the Dock. Nothing here opens a window.
        .testTarget(
            name: "LaunchpadAwakenerStandaloneCoreTests",
            dependencies: ["LaunchpadAwakenerStandaloneCore"]
        ),

        // The app's decision-making: daemon repair, which targets to inject, when displayed state has
        // gone stale, what the window's banner says. The daemon needs root and the payload only means
        // anything inside the Dock, so neither is exercised here.
        .testTarget(
            name: "LaunchpadAwakenerAppCoreTests",
            dependencies: ["LaunchpadAwakenerAppCore"]
        ),

        // The Dock's side: the build profiles. Read from the Dock binaries' facts, never from a live Dock.
        .testTarget(
            name: "LaunchpadAwakenerPayloadCoreTests",
            dependencies: ["LaunchpadAwakenerPayloadCore"]
        ),
    ]
)
