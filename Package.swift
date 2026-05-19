// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "AutoComp",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "AutoComp", targets: ["AutoCompApp"]),
        .library(name: "AutoCompCore", targets: ["AutoCompCore"])
    ],
    targets: [
        .executableTarget(
            name: "AutoCompApp",
            dependencies: ["AutoCompCore"]
        ),
        .target(
            name: "AutoCompCore"
        ),
        .testTarget(
            name: "AutoCompCoreTests",
            dependencies: ["AutoCompCore"]
        ),
        .testTarget(
            name: "AutoCompAppTests",
            dependencies: ["AutoCompApp"]
        )
    ]
)
