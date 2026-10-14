// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ApleTiming",
    platforms: [.iOS(.v15), .macOS(.v13)],
    products: [
        .library(name: "ApleTimingCore", targets: ["ApleTimingCore"]),
        .library(name: "ApleTimingUI", targets: ["ApleTimingUI"]),
    ],
    targets: [
        .target(name: "ApleTimingCore"),
        .target(name: "ApleTimingUI", dependencies: ["ApleTimingCore"]),
        .testTarget(name: "ApleTimingCoreTests", dependencies: ["ApleTimingCore"]),
    ]
)
