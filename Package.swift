// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "OpenVault",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "OpenVault", targets: ["OpenVault"]),
        .executable(name: "OpenVaultCoreTool", targets: ["OpenVaultCoreTool"]),
    ],
    dependencies: [
        .package(url: "https://github.com/kean/Nuke.git", exact: "13.0.6"),
        .package(
            url: "https://github.com/weichsel/ZIPFoundation.git",
            exact: "0.9.20"
        ),
    ],
    targets: [
        .executableTarget(
            name: "OpenVault",
            dependencies: [
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
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
        .executableTarget(
            name: "OpenVaultCoreTool",
            path: "Tools/OpenVaultCoreTool",
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
