// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Pace",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Pace", targets: ["Pace"])
    ],
    targets: [
        .executableTarget(name: "Pace")
    ]
)
