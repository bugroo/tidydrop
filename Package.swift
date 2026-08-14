// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "TidyDrop",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TidyDropCore", targets: ["TidyDropCore"]),
        .executable(name: "TidyDropApp", targets: ["TidyDropApp"]),
        .executable(name: "tidydrop", targets: ["TidyDrop"]),
        .executable(name: "tidydrop-agent", targets: ["TidyDropAgent"]),
        .executable(name: "tidydrop-self-test", targets: ["TidyDropSelfTests"])
    ],
    targets: [
        .target(
            name: "TidyDropCore",
            path: "Sources/TidyDropCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "TidyDrop",
            dependencies: ["TidyDropCore"],
            path: "Sources/TidyDrop"
        ),
        .executableTarget(
            name: "TidyDropApp",
            dependencies: ["TidyDropCore"],
            path: "Sources/TidyDropApp"
        ),
        .executableTarget(
            name: "TidyDropAgent",
            dependencies: ["TidyDropCore"],
            path: "Sources/TidyDropAgent"
        ),
        .executableTarget(
            name: "TidyDropSelfTests",
            dependencies: ["TidyDropCore"],
            path: "SelfTests/TidyDropSelfTests"
        )
    ]
)
