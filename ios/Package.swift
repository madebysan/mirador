// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ViewerCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "ViewerCore", targets: ["ViewerCore"]),
               .executable(name: "ViewerCheck", targets: ["ViewerCheck"])],
    targets: [
        .target(name: "ViewerCore", path: "Core"),
        .executableTarget(name: "ViewerCheck", dependencies: ["ViewerCore"], path: "Tools/ViewerCheck"),
        .testTarget(name: "ViewerCoreTests", dependencies: ["ViewerCore"], path: "Tests")
    ],
    swiftLanguageModes: [.v5]
)
