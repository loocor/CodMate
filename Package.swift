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
        // Embedded terminal support (optional at build time)
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "3.0.0")
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
