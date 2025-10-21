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
        .package(path: "SwiftTerm")
    ],
    targets: [
        .executableTarget(
            name: "CodMate",
            dependencies: [
                .product(name: "SwiftTerm", package: "SwiftTerm")
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
