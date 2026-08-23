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

var dependencies: [Package.Dependency] = []

#if os(macOS)
// Sparkle auto-updates (Developer ID distribution only; the framework is
// embedded in Contents/Frameworks by Scripts/build.sh). Declared only on
// macOS hosts so Linux CI never resolves it; the platform condition keeps it
// out of iOS cross-compiles.
dependencies.append(.package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"))
targets.append(
    .executableTarget(
        name: "FitsnFinish",
        dependencies: [
            "FitsnFinishCore",
            .product(name: "Sparkle", package: "Sparkle", condition: .when(platforms: [.macOS])),
        ],
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
        resources: [.process("Metal/SubtractEngine.metal")],
        linkerSettings: [
            .unsafeFlags(
                ["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"],
                .when(platforms: [.macOS])
            ),
        ]
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
    dependencies: dependencies,
    targets: targets
)
