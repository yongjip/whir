// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "whir",
    platforms: [.macOS(.v14)],   // floor raised for @Observable (Observation framework); App Store build already targets 14
    products: [
        .library(name: "WhirCore", targets: ["WhirCore"]),
        .executable(name: "whir", targets: ["whir"]),
        .executable(name: "WhirApp", targets: ["WhirApp"]),
    ],
    targets: [
        .target(name: "WhirCore"),
        .executableTarget(name: "whir", dependencies: ["WhirCore"]),
        .executableTarget(name: "WhirApp", dependencies: ["WhirCore"]),
        .testTarget(name: "WhirCoreTests", dependencies: ["WhirCore"]),
    ]
)
