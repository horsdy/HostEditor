// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HostEditor",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "HostEditor", targets: ["HostEditor"]),
        .executable(name: "HostEditorHelper", targets: ["HostEditorHelper"])
    ],
    targets: [
        .target(name: "FileSupport", publicHeadersPath: "include"),
        .target(name: "HostsCore", dependencies: ["FileSupport"]),
        .target(name: "HelperProtocol", dependencies: ["HostsCore"]),
        .executableTarget(name: "HostEditor", dependencies: ["HostsCore", "HelperProtocol"]),
        .executableTarget(name: "HostEditorHelper", dependencies: ["HostsCore", "HelperProtocol"]),
        // Standalone checks also run with Command Line Tools, where XCTest is absent.
        .executableTarget(name: "HostEditorChecks", dependencies: ["HostsCore", "HelperProtocol"], path: "Tests/HostEditorChecks")
    ]
)
