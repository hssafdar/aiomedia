// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "VocalRemoverCLI",
    platforms: [
        .macOS(.v12)
    ],
    targets: [
        .executableTarget(
            name: "VocalRemoverCLI",
            path: "Sources/VocalRemoverCLI"
        )
    ]
)
