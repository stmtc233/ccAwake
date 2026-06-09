// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ccAwake",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .library(name: "ccAwakeCore", targets: ["ccAwakeCore"]),
        .executable(name: "ccawake-hook", targets: ["ccawake-hook"]),
        .executable(name: "ccAwakeApp", targets: ["ccAwakeApp"]),
        .executable(name: "ccAwakeHelper", targets: ["ccAwakeHelper"])
    ],
    targets: [
        .target(name: "ccAwakeCore"),
        .executableTarget(
            name: "ccawake-hook",
            dependencies: ["ccAwakeCore"]
        ),
        .executableTarget(
            name: "ccAwakeApp",
            dependencies: ["ccAwakeCore"],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ServiceManagement")
            ]
        ),
        .executableTarget(
            name: "ccAwakeHelper",
            dependencies: ["ccAwakeCore"],
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Packaging/Helper-Info.plist"
                ])
            ]
        ),
        .testTarget(
            name: "ccAwakeCoreTests",
            dependencies: ["ccAwakeCore"]
        )
    ]
)
