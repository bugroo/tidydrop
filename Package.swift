// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "TidyDrop",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TidyDropCore", targets: ["TidyDropCore"]),
        .executable(name: "tidydrop", targets: ["TidyDrop"]),
        .executable(name: "tidydrop-self-test", targets: ["TidyDropSelfTests"])
    ],
    targets: [
        .target(
            name: "TidyDropCore",
            path: "Sources/TidyDropCore"
        ),
        .executableTarget(
            name: "TidyDrop",
            dependencies: ["TidyDropCore"],
            path: "Sources/TidyDrop"
        ),
        .executableTarget(
            name: "TidyDropSelfTests",
            dependencies: ["TidyDropCore"],
            path: "SelfTests/TidyDropSelfTests"
        )
    ]
)
