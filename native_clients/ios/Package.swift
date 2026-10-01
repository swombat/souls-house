// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SoulsHouseCore",
    products: [.library(name: "SoulsHouseCore", targets: ["SoulsHouseCore"])],
    targets: [
        .target(name: "SoulsHouseCore"),
        .testTarget(name: "SoulsHouseCoreTests", dependencies: ["SoulsHouseCore"])
    ]
)
