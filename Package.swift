// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Raindear",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Raindear", targets: ["Raindear"]),
        .executable(name: "rain-render", targets: ["rain-render"]),
    ],
    targets: [
        .target(name: "RainSynth"),
        .executableTarget(name: "Raindear", dependencies: ["RainSynth"]),
        .executableTarget(name: "rain-render", dependencies: ["RainSynth"]),
        .testTarget(name: "RainSynthTests", dependencies: ["RainSynth"]),
    ]
)
