// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "IOptron",
    defaultLocalization: "en",
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
        .target(name: "IOptronKit", dependencies: ["DriverLink"]),
        // The iPad's connection to Overpass's own USB serial driver (Driver/).
        .target(name: "DriverLink", linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.iOS]))]),
        // Resources: the names SkyKit shows (Sun, Moon, planets, kinds of object), in Localizable.xcstrings.
        .target(name: "SkyKit", dependencies: ["SatelliteKit"], resources: [.process("Resources")]),
        // Exposure and gain on USB video cameras, which AVFoundation doesn't offer on a Mac.
        .target(name: "UVCControl", linkerSettings: [.linkedFramework("IOKit", .when(platforms: [.macOS]))]),
        .testTarget(name: "IOptronKitTests", dependencies: ["IOptronKit"]),
        .testTarget(name: "SkyKitTests", dependencies: ["SkyKit"]),
    ]
)
