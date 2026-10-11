// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "speakr-asr-wrapper",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.17.7"),
        .package(url: "https://github.com/vapor/vapor.git", from: "4.99.0"),
    ],
    targets: [
        .executableTarget(
            name: "SpeakrASRWrapper",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "Vapor", package: "vapor"),
            ]
        )
    ]
)
