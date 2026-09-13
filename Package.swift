// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rain",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Rain", targets: ["Rain"]),
        .executable(name: "rain-render", targets: ["rain-render"]),
    ],
    targets: [
        .target(name: "RainSynth"),
        .executableTarget(name: "Rain", dependencies: ["RainSynth"]),
        .executableTarget(name: "rain-render", dependencies: ["RainSynth"]),
        .testTarget(name: "RainSynthTests", dependencies: ["RainSynth"]),
    ]
)
