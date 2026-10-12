// swift-tools-version:5.9
// DrivebyCore — the pure-Swift logic of the Driveby iOS app (Driveby/Core), packaged
// so it can be unit-tested with `swift test` on macOS or Linux, without a simulator.
// The iOS app compiles the very same files directly (Xcode synchronized folder).
import PackageDescription

let package = Package(
    name: "DrivebyCore",
    products: [.library(name: "DrivebyCore", targets: ["DrivebyCore"])],
    targets: [
        .target(name: "DrivebyCore", path: "Driveby/Core"),
        .testTarget(
            name: "DrivebyCoreTests",
            dependencies: ["DrivebyCore"],
            path: "Tests/DrivebyCoreTests",
            resources: [.copy("Fixtures")]
        ),
    ]
)
