// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ClipNest",
    defaultLocalization: "zh-Hans",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ClipNestCore", targets: ["ClipNestCore"]),
        .executable(name: "ClipNest", targets: ["ClipNest"])
    ],
    targets: [
        .target(name: "ClipNestCore", path: "macOS/Sources/Core"),
        .executableTarget(name: "ClipNest", dependencies: ["ClipNestCore"], path: "macOS",
                          exclude: ["Sources/Core", "Tests", "Info.plist", "build.sh", "install.sh", "test.sh", "compiler-flags.sh", "check-strings.sh", "check-docs.sh"],
                          sources: ["Sources"], resources: [.process("Resources")]),
        .testTarget(name: "ClipNestCoreTests", dependencies: ["ClipNestCore"], path: "Tests/ClipNestCoreTests")
    ]
)
