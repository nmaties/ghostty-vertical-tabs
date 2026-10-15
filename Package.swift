// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "GhosttyVerticalTabs",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "GhosttyVerticalTabs", path: "Sources/GhosttyVerticalTabs")
    ]
)
