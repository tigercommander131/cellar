// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CellarKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "CellarKit", targets: ["CellarKit"]),
        .executable(name: "cellar", targets: ["cellar"]),
    ],
    targets: [
        .target(name: "CellarKit"),
        .executableTarget(name: "cellar", dependencies: ["CellarKit"]),
        .testTarget(name: "CellarKitTests", dependencies: ["CellarKit"]),
    ]
)
