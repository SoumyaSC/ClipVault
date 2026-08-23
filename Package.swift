// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "ClipVault",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        // All app logic lives in the core library so both executables link it.
        .target(
            name: "ClipVaultCore",
            path: "Sources/ClipVaultCore"
        ),
        .executableTarget(
            name: "ClipVault",
            dependencies: ["ClipVaultCore"],
            path: "Sources/ClipVault"
        ),
        // Command Line Tools ship no XCTest framework, so tests are a plain
        // executable with a bundled assertion harness (see Tests/*/TestKit.swift).
        .executableTarget(
            name: "ClipVaultTests",
            dependencies: ["ClipVaultCore"],
            path: "Tests/ClipVaultTests"
        )
    ]
)
