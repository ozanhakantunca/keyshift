// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KeyshiftE2E",
    platforms: [.macOS(.v13)],
    targets: [.executableTarget(name: "KeyshiftE2E")],
    swiftLanguageModes: [.v5]
)
