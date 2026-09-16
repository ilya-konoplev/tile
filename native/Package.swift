// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ActivityHeatmap",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "ActivityHeatmap",
            path: "Sources/ActivityHeatmap",
            linkerSettings: [
                .linkedLibrary("sqlite3")
            ]
        )
    ]
)
