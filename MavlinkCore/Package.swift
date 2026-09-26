// swift-tools-version: 6.0
import PackageDescription

// Everything about MAVLink that is not a screen: the codec, the link, and
// the state the vehicle reports. Kept apart from the app so it can be
// built and tested on the Mac with `swift test`, no simulator involved.
let package = Package(
    name: "MavlinkCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MavlinkCore", targets: ["MavlinkCore"]),
    ],
    targets: [
        .target(name: "MavlinkCore"),
        .testTarget(
            name: "MavlinkCoreTests",
            dependencies: ["MavlinkCore"],
            resources: [.copy("Vectors")]
        ),
    ]
)
