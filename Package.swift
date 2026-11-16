// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Rafale",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0")
    ],
    targets: [
        .executableTarget(
            name: "Rafale",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Rafale",
            linkerSettings: [
                // Sparkle.framework est embarqué dans Contents/Frameworks par build.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
