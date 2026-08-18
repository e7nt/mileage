// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Mileage",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MileageCore", targets: ["MileageCore"]),
        .executable(name: "Mileage", targets: ["Mileage"]),
    ],
    targets: [
        .target(name: "MileageCore"),
        .executableTarget(
            name: "Mileage",
            dependencies: ["MileageCore"]
        ),
        .testTarget(
            name: "MileageCoreTests",
            dependencies: ["MileageCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
