// swift-tools-version: 6.0
import PackageDescription

// TestFlight from the command line, through the App Store Connect API: test information,
// groups, builds, review submissions and testers. Kept out of the app's package; nothing to
// install, since the tokens are signed with CryptoKit.
let package = Package(
    name: "TestFlight",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TestFlightKit"),
        .executableTarget(name: "testflight", dependencies: ["TestFlightKit"]),
        .testTarget(name: "TestFlightKitTests", dependencies: ["TestFlightKit"]),
    ]
)
