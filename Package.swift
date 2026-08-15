// swift-tools-version: 5.7
import PackageDescription

let package = Package(
    name: "TidyDrop",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "TidyDropCore", targets: ["TidyDropCore"]),
        .library(name: "TidyDropUpdateSecurity", targets: ["TidyDropUpdateSecurity"]),
        .library(name: "TidyDropUpdateTransport", targets: ["TidyDropUpdateTransport"]),
        .library(name: "TidyDropUpdateInspection", targets: ["TidyDropUpdateInspection"]),
        .library(name: "TidyDropUpdateRecovery", targets: ["TidyDropUpdateRecovery"]),
        .executable(name: "TidyDropApp", targets: ["TidyDropApp"]),
        .executable(name: "tidydrop", targets: ["TidyDrop"]),
        .executable(name: "tidydrop-agent", targets: ["TidyDropAgent"]),
        .executable(
            name: "tidydrop-recovery-helper",
            targets: ["TidyDropRecoveryHelper"]
        ),
        .executable(name: "tidydrop-self-test", targets: ["TidyDropSelfTests"])
    ],
    targets: [
        .target(
            name: "TidyDropCore",
            path: "Sources/TidyDropCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
                .linkedFramework("Security", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "TidyDropUpdateSecurity",
            dependencies: ["TidyDropCore"],
            path: "Sources/TidyDropUpdateSecurity"
        ),
        .target(
            name: "TidyDropUpdateTransport",
            dependencies: ["TidyDropUpdateSecurity"],
            path: "Sources/TidyDropUpdateTransport"
        ),
        .target(
            name: "TidyDropUpdateInspection",
            dependencies: ["TidyDropUpdateSecurity"],
            path: "Sources/TidyDropUpdateInspection",
            linkerSettings: [
                .linkedFramework("Security", .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "TidyDropUpdateRecovery",
            dependencies: [
                "TidyDropCore",
                "TidyDropUpdateSecurity",
                "TidyDropUpdateInspection"
            ],
            path: "Sources/TidyDropUpdateRecovery"
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
            name: "TidyDropRecoveryHelper",
            dependencies: ["TidyDropUpdateRecovery"],
            path: "Sources/TidyDropRecoveryHelper"
        ),
        .executableTarget(
            name: "TidyDropSelfTests",
            dependencies: [
                "TidyDropCore",
                "TidyDropUpdateSecurity",
                "TidyDropUpdateTransport",
                "TidyDropUpdateInspection",
                "TidyDropUpdateRecovery"
            ],
            path: "SelfTests/TidyDropSelfTests"
        )
    ]
)
