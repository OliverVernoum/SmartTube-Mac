// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SmartTube",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SmartTube", targets: ["SmartTube"])
    ],
    targets: [
        .executableTarget(
            name: "SmartTube",
            path: "Sources/SmartTube",
            resources: [.copy("Resources/nsigsolver")]
        ),
        .testTarget(
            name: "SmartTubeTests",
            dependencies: ["SmartTube"],
            path: "Tests/SmartTubeTests",
            resources: [.copy("Fixtures")]
        )
    ]
)
