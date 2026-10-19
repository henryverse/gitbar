// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "GitBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "gitbar", targets: ["gitbar"]),
        .executable(name: "GitBarApp", targets: ["GitBarApp"]),
    ],
    targets: [
        .target(name: "GitBarCore"),
        .executableTarget(name: "gitbar", dependencies: ["GitBarCore"]),
        .executableTarget(name: "GitBarApp", dependencies: ["GitBarCore"]),
    ]
)
