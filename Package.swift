// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ThoughtStream",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ThoughtStream", targets: ["ThoughtStream"])],
    dependencies: [.package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")],
    targets: [
        .target(name: "GitDiff", path: "Sources/GitDiff", exclude: ["UPSTREAM.md", "LICENSE"]),
        .executableTarget(name: "ThoughtStream", dependencies: ["GitDiff", .product(name: "Sparkle", package: "Sparkle")], path: "Sources/Unfold", exclude: ["Renderer"], resources: [.copy("Tools"), .copy("ThirdPartyNotices")], linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "ThoughtStreamTests", dependencies: ["ThoughtStream"], path: "Tests/UnfoldTests")
    ]
)
