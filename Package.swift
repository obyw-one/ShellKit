// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ShellKit",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ShellKit", targets: ["ShellKit"]),
    ],
    targets: [
        // Leaf package: Foundation only. Zero ShiKit / shikki-monorepo deps.
        // Contains the canonical async subprocess primitives extracted from
        // Sources/ShiKit/Shell/ per features/shellkit-hoist-2026-06-04.md W1.
        .target(name: "ShellKit"),
        .testTarget(
            name: "ShellKitTests",
            dependencies: ["ShellKit"]
        ),
    ]
)
