// swift-tools-version:5.1
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "HaishinKit",
    platforms: [
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "HaishinKit", targets: ["HaishinKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/shogo4405/Logboard.git", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "HaishinKit",
            dependencies: ["Logboard"])
    ]
)
