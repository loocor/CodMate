// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "CodMate",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "CodMate",
            targets: ["CodMate"]
        )
    ],
    targets: [
        .executableTarget(
            name: "CodMate",
            path: "Sources"
        ),
        .testTarget(
            name: "CodMateTests",
            dependencies: ["CodMate"],
            path: "Tests"
        )
    ]
)
