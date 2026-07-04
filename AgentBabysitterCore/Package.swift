// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentBabysitterCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AgentBabysitterCore", targets: ["AgentBabysitterCore"])
    ],
    targets: [
        .target(name: "AgentBabysitterCore"),
        .testTarget(
            name: "AgentBabysitterCoreTests",
            dependencies: ["AgentBabysitterCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
