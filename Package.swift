// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ForgeCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [.library(name: "ForgeCore", targets: ["ForgeCore"])],
    targets: [
        .target(name: "ForgeCore"),
        .testTarget(name: "ForgeCoreTests", dependencies: ["ForgeCore"])
    ]
)
