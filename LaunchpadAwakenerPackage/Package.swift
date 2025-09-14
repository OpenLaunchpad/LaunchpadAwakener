// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "LaunchpadAwakenerPackage",
    platforms: [.macOS(.v26)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "LaunchpadAwakenerCommunication",
            targets: ["LaunchpadAwakenerCommunication"]
        ),
        .library(
            name: "LaunchpadAwakenerShim",
            targets: ["LaunchpadAwakenerShim"]
        ),
        .library(
            name: "LaunchpadAwakenerServer",
            targets: ["LaunchpadAwakenerServer"]
        ),
        .library(
            name: "LaunchpadAwakenerCore",
            targets: ["LaunchpadAwakenerCore"]
        ),
        .library(
            name: "LaunchpadAwakenerDaemon",
            targets: ["LaunchpadAwakenerDaemon"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/Mx-Iris/swift-helper-service", branch: "main"),
        .package(url: "https://github.com/mhdhejazi/Dynamic", from: "1.2.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "LaunchpadAwakenerCommunication",
            dependencies: [
                .product(name: "HelperService", package: "swift-helper-service"),
            ]
        ),
        .target(
            name: "LaunchpadAwakenerCore",
            dependencies: [
                .product(name: "HelperService", package: "swift-helper-service"),
                .product(name: "HelperClient", package: "swift-helper-service"),
                .product(name: "InjectionService", package: "swift-helper-service"),
            ]
        ),
        .target(
            name: "LaunchpadAwakenerServer",
            dependencies: [
                "LaunchpadAwakenerShim",
                "LaunchpadAwakenerCommunication",
                .product(name: "Dynamic", package: "Dynamic"),
                .product(name: "HelperService", package: "swift-helper-service"),
                .product(name: "HelperServer", package: "swift-helper-service"),
            ]
        ),
        .target(
            name: "LaunchpadAwakenerDaemon",
            dependencies: [
                .product(name: "HelperService", package: "swift-helper-service"),
                .product(name: "HelperServer", package: "swift-helper-service"),
                .product(name: "InjectionService", package: "swift-helper-service"),
            ]
        ),
        .target(
            name: "LaunchpadAwakenerShim"
        ),
    ]
)
