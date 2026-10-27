// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IOptron",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "IOptronKit", targets: ["IOptronKit"]),
        .library(name: "SkyKit", targets: ["SkyKit"]),
        .library(name: "UVCControl", targets: ["UVCControl"]),
    ],
    dependencies: [
        .package(url: "https://github.com/gavineadie/SatelliteKit.git", exact: "2.1.2"),
    ],
    targets: [
        .target(name: "IOptronKit"),
        .target(name: "SkyKit", dependencies: ["SatelliteKit"]),
        // Exposure and gain on USB video cameras, which AVFoundation doesn't offer on a Mac.
        .target(name: "UVCControl", linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS]))]),
        .testTarget(name: "IOptronKitTests", dependencies: ["IOptronKit"]),
        .testTarget(name: "SkyKitTests", dependencies: ["SkyKit"]),
    ]
)
