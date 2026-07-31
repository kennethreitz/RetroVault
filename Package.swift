// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "RetroVault",
    platforms: [
        .macOS(.v26),
    ],
    products: [
        .executable(name: "RetroVault", targets: ["RetroVault"]),
        .executable(name: "RetroVaultCoreTool", targets: ["RetroVaultCoreTool"]),
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
            name: "RetroVault",
            dependencies: [
                "RetroVaultLibretroLogShim",
                .product(name: "Nuke", package: "Nuke"),
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "RetroVault",
            exclude: [
                "App/Info.plist",
                "App/RetroVault.entitlements",
                "Shared/LibretroLogShim",
            ],
            resources: [
                .process("Resources"),
            ]
        ),
        .target(
            name: "RetroVaultLibretroLogShim",
            path: "RetroVault/Shared/LibretroLogShim",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "RetroVaultTests",
            dependencies: [
                "RetroVault",
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ],
            path: "RetroVaultTests"
        ),
        .executableTarget(
            name: "RetroVaultCoreTool",
            path: "Tools/RetroVaultCoreTool",
            exclude: ["Fixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
