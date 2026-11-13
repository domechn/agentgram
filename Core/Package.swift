// swift-tools-version:5.9
import PackageDescription

// Pure logic only. The app itself is built from project.yml (XcodeGen).
let package = Package(
    name: "AgentCore",
    platforms: [.macOS(.v14)],
    products: [.library(name: "AgentCore", targets: ["AgentCore"])],
    targets: [
        .target(name: "AgentCore"),
        .testTarget(name: "AgentCoreTests", dependencies: ["AgentCore"]),
    ]
)
