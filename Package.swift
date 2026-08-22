// swift-tools-version:5.10
import PackageDescription

var targets: [Target] = [
    .target(
        name: "FitsnFinishCore",
        path: "Core"
    ),
    .testTarget(
        name: "FitsnFinishTests",
        dependencies: ["FitsnFinishCore"],
        path: "Tests"
    ),
]

var products: [Product] = [
    .library(name: "FitsnFinishCore", targets: ["FitsnFinishCore"]),
]

#if os(macOS)
targets.append(
    .executableTarget(
        name: "FitsnFinish",
        dependencies: ["FitsnFinishCore"],
        path: ".",
        exclude: [
            "build",
            "Core",
            "Tests",
            "Scripts",
            "Support",
            "ci_scripts",
            "Dockerfile",
            "LICENSE.md",
            "README.md",
            "fitsnfinish.md",
        ],
        sources: ["App"],
        resources: [.process("Metal/SubtractEngine.metal")]
    )
)
products.append(.executable(name: "FitsnFinish", targets: ["FitsnFinish"]))
#endif

let package = Package(
    name: "FitsnFinish",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    products: products,
    targets: targets
)
