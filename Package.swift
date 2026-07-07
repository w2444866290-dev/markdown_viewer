// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "MarkdownViewer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MarkdownViewer",
            path: "Sources/MarkdownViewer",
            resources: [.process("../../Resources")]
        ),
        .testTarget(
            name: "MarkdownViewerTests",
            dependencies: ["MarkdownViewer"],
            path: "Tests/MarkdownViewerTests"
        )
    ]
)
