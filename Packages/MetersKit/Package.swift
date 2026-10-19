// swift-tools-version: 6.2

import PackageDescription

let strictSettings: [SwiftSetting] = [
    .treatAllWarnings(as: .error)
]

let package = Package(
    name: "MetersKit",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MetersCore", targets: ["MetersCore"]),
        .library(name: "MetersUI", targets: ["MetersUI"]),
        .executable(name: "meters-probe", targets: ["MetersProbe"]),
    ],
    targets: [
        // Pure logic: settings, layout math, data sources. Foundation only.
        .target(name: "MetersCore", swiftSettings: strictSettings),
        // AppKit and SwiftUI surfaces: the HUD panel, container, and controller.
        .target(name: "MetersUI", dependencies: ["MetersCore"], swiftSettings: strictSettings),
        // Development tool used by `make smoke` and `make perf`; never linked into the app.
        .executableTarget(name: "MetersProbe", swiftSettings: strictSettings),
        .testTarget(name: "MetersCoreTests", dependencies: ["MetersCore"], swiftSettings: strictSettings),
        .testTarget(
            name: "MetersUITests", dependencies: ["MetersUI", "MetersCore"], swiftSettings: strictSettings),
    ]
)
