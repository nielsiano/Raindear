// swift-tools-version:5.9
import PackageDescription

// The stack protector makes wasi-libc seed its guard with random_get, which would be the module's only import.
let wasm: [SwiftSetting] = [.unsafeFlags(["-disable-stack-protector"], .when(platforms: [.wasi]))]

let package = Package(
    name: "Raindear",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "Raindear", targets: ["Raindear"]),
        .executable(name: "rain-render", targets: ["rain-render"]),
        .executable(name: "rain-wasm", targets: ["rain-wasm"]),
    ],
    targets: [
        .target(name: "RainSynth", swiftSettings: wasm),
        .executableTarget(name: "Raindear", dependencies: ["RainSynth"]),
        .executableTarget(name: "rain-render", dependencies: ["RainSynth"]),
        .executableTarget(
            name: "rain-wasm",
            dependencies: ["RainSynth"],
            swiftSettings: wasm,
            linkerSettings: [.unsafeFlags(["-Xclang-linker", "-mexec-model=reactor", "-Xlinker", "--strip-all"], .when(platforms: [.wasi]))]
        ),
        .testTarget(name: "RainSynthTests", dependencies: ["RainSynth"]),
    ]
)
