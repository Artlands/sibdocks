// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "SibDocks",
    platforms: [.macOS(.v26)],
    targets: [.executableTarget(name: "SibDocks", path: "Sources/SibDocks")]
)
