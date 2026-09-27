// swift-tools-version: 6.0
import PackageDescription

// Everything that is not a screen: the MAVLink codec, the link, the state
// the vehicle reports, and the terrain under it. Kept apart from the app
// so it can be built and tested on the Mac with `swift test`, no simulator
// involved.
let package = Package(
    name: "MavlinkCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "MavlinkCore", targets: ["MavlinkCore"]),
        .library(name: "TerrainCore", targets: ["TerrainCore"]),
    ],
    targets: [
        .target(name: "MavlinkCore"),
        .testTarget(
            name: "MavlinkCoreTests",
            dependencies: ["MavlinkCore"],
            resources: [.copy("Vectors")]
        ),
        // Ground heights from the Copernicus GLO-30 DEM, for the terrain
        // radar. Nothing to do with MAVLink, so a module of its own.
        .target(name: "TerrainCore"),
        .testTarget(name: "TerrainCoreTests", dependencies: ["TerrainCore"]),
    ]
)
