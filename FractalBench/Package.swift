// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "FractalBench",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "fractalbench", targets: ["FractalBench"]) 
    ],
    targets: [
        .executableTarget(
            name: "FractalBench",
            path: "Sources"
        )
    ]
)
