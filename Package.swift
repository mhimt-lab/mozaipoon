// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "wipe-mosaic",
    platforms: [.macOS("26.0")],
    targets: [
        .target(name: "WipeMosaicCore", path: "Sources/WipeMosaicCore", swiftSettings: v5),
        .executableTarget(
            name: "wipe-mosaic", dependencies: ["WipeMosaicCore"], path: "Sources/wipe-mosaic",
            swiftSettings: v5),
        .executableTarget(
            name: "WipeMosaic", dependencies: ["WipeMosaicCore"], path: "Sources/WipeMosaicApp",
            swiftSettings: v5),
    ]
)
