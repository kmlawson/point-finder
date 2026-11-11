// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "PointFinder",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "PointFinderCore"),
        .executableTarget(name: "PointFinder", dependencies: ["PointFinderCore"]),
        .executableTarget(name: "pointfinder-cli", dependencies: ["PointFinderCore"]),
        .testTarget(name: "PointFinderCoreTests", dependencies: ["PointFinderCore"]),
    ]
)
