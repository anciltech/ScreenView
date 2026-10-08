// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScreenView",
    platforms: [.iOS(.v17), .macOS(.v14), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: [.library(name: "ScreenView", targets: ["ScreenView"])],
    targets: [
        .target(name: "ScreenView"),
        .testTarget(name: "ScreenViewTests", dependencies: ["ScreenView"])
    ]
)
