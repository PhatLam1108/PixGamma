// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PixGamma",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PixGammaCore", targets: ["PixGammaCore"]),
        .executable(name: "pixgamma", targets: ["pixgamma"]),
        .executable(name: "PixGammaApp", targets: ["PixGammaApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
        .package(url: "https://github.com/apple/ml-stable-diffusion", exact: "1.1.1"),
    ],
    targets: [
        .target(
            name: "PixGammaCore",
            dependencies: [.product(name: "StableDiffusion", package: "ml-stable-diffusion")]
        ),
        .executableTarget(
            name: "pixgamma",
            dependencies: [
                "PixGammaCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "PixGammaApp", dependencies: ["PixGammaCore"]),
        .testTarget(name: "PixGammaCoreTests", dependencies: ["PixGammaCore"]),
    ],
    swiftLanguageModes: [.v5]
)
