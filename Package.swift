// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "storescreens-cli",
    platforms: [
        .macOS(.v14),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser.git", from: "1.3.0"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.1.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.12.0"),
    ],
    targets: [
        // Build plugin: generates Version.swift from the VERSION file
        .executableTarget(
            name: "GenerateVersionTool",
            dependencies: []
        ),
        .plugin(
            name: "GenerateVersion",
            capability: .buildTool(),
            dependencies: ["GenerateVersionTool"]
        ),

        // Shared core library used by both CLI and MCP
        .target(
            name: "StorescreensCore",
            dependencies: [
                .product(name: "Yams", package: "Yams"),
            ],
            resources: [
                .process("Resources"),
            ],
            plugins: ["GenerateVersion"]
        ),

        // CLI executable
        .executableTarget(
            name: "storescreens-cli",
            dependencies: [
                "StorescreensCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),

        // MCP server executable
        .executableTarget(
            name: "storescreens-mcp",
            dependencies: [
                "StorescreensCore",
                .product(name: "MCP", package: "swift-sdk"),
            ]
        ),

        .testTarget(
            name: "StorescreensCoreTests",
            dependencies: ["StorescreensCore"]
        ),
    ]
)
