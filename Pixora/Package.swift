// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Pixora",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PixoraCore", targets: ["PixoraCore"]),
        .executable(name: "pixora", targets: ["pixora"]),
        .executable(name: "PixoraApp", targets: ["PixoraApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/ml-stable-diffusion", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "PixoraCore",
            dependencies: [.product(name: "StableDiffusion", package: "ml-stable-diffusion")]
        ),
        .executableTarget(
            name: "pixora",
            dependencies: [
                "PixoraCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "PixoraApp", dependencies: ["PixoraCore"]),
        .testTarget(name: "PixoraCoreTests", dependencies: ["PixoraCore"]),
    ],
    swiftLanguageModes: [.v5]
)
