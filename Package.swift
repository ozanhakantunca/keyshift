// swift-tools-version:6.0
// Keyshift — free & open-source keyboard remapper for macOS (GPL-3.0)
import PackageDescription

let package = Package(
    name: "Keyshift",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Keyshift", targets: ["Keyshift"]),
    ],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        // Menu bar app, settings UI, onboarding, CLI. Bundled into Keyshift.app by scripts/build-app.sh
        .executableTarget(
            name: "Keyshift",
            dependencies: ["KeyshiftCore", "KeyshiftConfig", "KeyshiftSystem"],
            path: "Sources/App"
        ),
        // macOS integration: CGEventTap backend, context providers (frontmost app, AX text focus),
        // action executor, permissions, Karabiner coexistence, system shortcut reader.
        .target(
            name: "KeyshiftSystem",
            dependencies: ["KeyshiftCore", "KeyshiftConfig"],
            path: "Sources/System"
        ),
        // Config file format: YAML parse/serialize, presets, karabiner.json importer, conflict detection.
        .target(
            name: "KeyshiftConfig",
            dependencies: ["KeyshiftCore", .product(name: "Yams", package: "Yams")],
            path: "Sources/Config",
            resources: [.copy("Presets")]
        ),
        // Pure logic: key model, rule model, remapping engine. No AppKit, no CoreGraphics event APIs.
        .target(
            name: "KeyshiftCore",
            path: "Sources/Core"
        ),
        .testTarget(name: "KeyshiftAppTests", dependencies: ["Keyshift", "KeyshiftConfig", "KeyshiftCore"], path: "Tests/AppTests"),
        .testTarget(name: "KeyshiftCoreTests", dependencies: ["KeyshiftCore"], path: "Tests/CoreTests"),
        .testTarget(name: "KeyshiftConfigTests", dependencies: ["KeyshiftConfig"], path: "Tests/ConfigTests"),
        .testTarget(name: "KeyshiftSystemTests", dependencies: ["KeyshiftSystem"], path: "Tests/SystemTests"),
    ],
    swiftLanguageModes: [.v5]
)
