// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "AllNighter",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "AllNighter",
            path: "Sources/AllNighter"
        )
    ]
)
