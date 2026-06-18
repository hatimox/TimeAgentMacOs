// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TimeAgentMac",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "TimeAgentMac",
            path: "TimeAgentMac"
        )
    ]
)
