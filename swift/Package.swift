// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Watermark",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "WatermarkCore", targets: ["WatermarkCore"]),
        .executable(name: "watermark-app", targets: ["WatermarkApp"])
    ],
    targets: [
        .target(
            name: "WatermarkCore",
            dependencies: [],
            path: "Sources/WatermarkCore"
        ),
        .executableTarget(
            name: "WatermarkApp",
            dependencies: ["WatermarkCore"],
            path: "Sources/WatermarkApp"
        ),
        .testTarget(
            name: "WatermarkCoreTests",
            dependencies: ["WatermarkCore"],
            path: "Tests/WatermarkCoreTests"
        )
    ]
)
