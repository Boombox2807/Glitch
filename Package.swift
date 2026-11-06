// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "GlitchAI",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(name: "GlitchAI", path: "Sources/GlitchAI")
    ]
)
