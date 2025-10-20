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
        // Embedded terminal support (align with Xcode project 1.5.x)
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.5.1")
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
