// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EmberSyncKit",
    platforms: [.iOS("17.5"), .macOS(.v14)],
    products: [.library(name: "EmberSyncKit", targets: ["EmberSyncKit"])],
    targets: [
        .target(name: "EmberSyncKit"),
        .testTarget(name: "EmberSyncKitTests", dependencies: ["EmberSyncKit"])
    ]
)
