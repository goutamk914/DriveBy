// swift-tools-version:5.9
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
