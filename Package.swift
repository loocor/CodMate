// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodMate",
    platforms: [.macOS(.v15)],
    products: [
        .executable(
            name: "CodMate",
            targets: ["CodMate"]
        )
    ],
    dependencies: [
        // Embedded terminal support (use local checkout for development)
        .package(path: "SwiftTerm"),
        // MCP Swift SDK for real MCP client connections
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.10.0")
    ],
    targets: [
        .executableTarget(
            name: "CodMate",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm"),
                .product(name: "MCP", package: "swift-sdk")
            ],
            path: "Sources"
        ),
        .testTarget(
            name: "CodMateTests",
            dependencies: ["CodMate"],
            path: "Tests"
        ),
    ]
)
