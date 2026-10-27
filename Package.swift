// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "AIWrapped",
    platforms: [.macOS(.v15)],
    targets: [
        .executableTarget(
            name: "AIWrapped",
            path: "Sources/AIWrapped",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("sqlite3")]
        )
    ]
)
