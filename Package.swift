// swift-tools-version: 6.0
import PackageDescription

// The test target links Testing.framework. The Command Line Tools ship it
// outside the default search path, so upstream pointed the compiler and linker
// at the CLT copy unconditionally. With full Xcode selected that copy can be
// OLDER than the toolchain's swift-testing macros (Xcode 27: `Testing.
// __SourceBounds` missing) and the tests fail to build. Opt in to the CLT paths
// only when actually building with the Command Line Tools:
//   FOREL_TESTING_FROM_CLT=1 swift test
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let testsFromCLT = Context.environment["FOREL_TESTING_FROM_CLT"] != nil

let package = Package(
    name: "Forel",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "ForelCore", targets: ["ForelCore"]),
        .executable(name: "ForelApp", targets: ["ForelApp"]),
        .executable(name: "foreld", targets: ["foreld"]),
    ],
    dependencies: [
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.18"),
        .package(url: "https://github.com/jpsim/Yams.git", from: "6.2.2"),
    ],
    targets: [
        .target(
            name: "ForelCore",
            dependencies: [
                .product(name: "ZIPFoundation", package: "ZIPFoundation"),
            ]
        ),
        .executableTarget(
            name: "ForelApp",
            dependencies: ["ForelCore"],
            resources: [.copy("Resources")]
        ),
        // Headless Forel: the same engine, watcher and database, driven from a
        // YAML rules file and a LaunchAgent instead of the SwiftUI app.
        .executableTarget(
            name: "foreld",
            dependencies: [
                "ForelCore",
                .product(name: "Yams", package: "Yams"),
            ]
        ),
        .testTarget(
            name: "ForelCoreTests",
            dependencies: ["ForelCore"],
            swiftSettings: testsFromCLT ? [.unsafeFlags(["-F\(cltFrameworks)"])] : [],
            linkerSettings: testsFromCLT ? [
                .unsafeFlags([
                    "-F\(cltFrameworks)",
                    "-Xlinker", "-rpath",
                    "-Xlinker", cltFrameworks,
                    "-Xlinker", "-rpath",
                    "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
                ])
            ] : []
        ),
    ]
)
