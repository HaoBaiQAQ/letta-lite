// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "LettaLite",
    platforms: [
        .iOS(.v14),
        .macOS(.v11)
    ],
    products: [
        .library(
            name: "LettaLite",
            targets: ["LettaLite", "LettaLiteFFI"]
        )
    ],
    targets: [
        .target(
            name: "LettaLite",
            dependencies: ["LettaLiteFFI"],
            path: "Sources/LettaLite"
        ),
        .binaryTarget(
            name: "LettaLiteFFI",
            path: "LettaLite.xcframework"
        ),
        .testTarget(
            name: "LettaLiteTests",
            dependencies: ["LettaLite"],
            path: "Tests/LettaLiteTests"
        )
    ]
)