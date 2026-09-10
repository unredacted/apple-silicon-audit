// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SiliconAudit",
    defaultLocalization: "en",
    platforms: [
        // iOS 18 is the floor so the spec's A12-era device test (iOS 18 max) stays possible.
        .iOS(.v18), .macOS(.v15), .watchOS(.v11), .tvOS(.v18), .visionOS(.v2),
    ],
    products: [
        .library(name: "SiliconAuditCore", targets: ["SiliconAuditCore"]),
        .library(name: "SiliconAuditUI", targets: ["SiliconAuditUI"]),
        .executable(name: "silicon-audit", targets: ["silicon-audit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.8.2"),
    ],
    targets: [
        // Probe engine. No UI. Platform conditionals only in Environment.swift.
        .target(
            name: "SiliconAuditCore",
            resources: [.process("Resources")]
        ),
        // Shared SwiftUI views.
        .target(
            name: "SiliconAuditUI",
            dependencies: ["SiliconAuditCore"],
            resources: [.process("Resources")]
        ),
        // macOS command-line tool linking the same core.
        .executableTarget(
            name: "silicon-audit",
            dependencies: [
                "SiliconAuditCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "SiliconAuditCoreTests",
            dependencies: ["SiliconAuditCore"]
        ),
        .testTarget(
            name: "SiliconAuditUITests",
            dependencies: ["SiliconAuditUI", "SiliconAuditCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
