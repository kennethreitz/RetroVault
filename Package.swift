// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenVault",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "OpenVault", targets: ["OpenVault"]),
    ],
    dependencies: [
        .package(url: "https://github.com/kean/Nuke.git", exact: "13.0.6"),
    ],
    targets: [
        .executableTarget(
            name: "OpenVault",
            dependencies: [
                .product(name: "Nuke", package: "Nuke"),
            ],
            path: "OpenVault",
            exclude: [
                "App/Info.plist",
                "App/OpenVault.entitlements",
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "OpenVaultTests",
            dependencies: ["OpenVault"],
            path: "OpenVaultTests"
        ),
    ],
    swiftLanguageModes: [.v6]
)
