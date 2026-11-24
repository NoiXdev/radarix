// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RadarixKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "RadarixKit", targets: ["RadarixKit"]),
    ],
    targets: [
        .target(name: "RadarixKit"),
        .testTarget(name: "RadarixKitTests", dependencies: ["RadarixKit"]),
    ]
)
