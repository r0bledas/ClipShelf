// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ClipShelf",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "ClipShelfCore", targets: ["ClipShelfCore"]),
        .executable(name: "ClipShelf", targets: ["ClipShelf"])
    ],
    targets: [
        .target(
            name: "ClipShelfCore",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "ClipShelf",
            dependencies: ["ClipShelfCore"],
            resources: [
                .process("Resources")
            ],
            linkerSettings: [
                .linkedFramework("Carbon"),
                .linkedFramework("LinkPresentation"),
                .linkedFramework("QuickLookUI"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .testTarget(
            name: "ClipShelfCoreTests",
            dependencies: ["ClipShelfCore"]
        )
    ]
)
