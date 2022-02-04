// swift-tools-version:4.2

import PackageDescription

let package = Package(
    name: "HaishinKit",
    
    products: [
        .library(name: "HaishinKit", targets: ["HaishinKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/shogo4405/Logboard.git", from: "1.0.0"),
    ],
    targets: [
        // Targets are the basic building blocks of a package. A target defines a module or a test suite.
        // Targets can depend on other targets in this package, and on products in packages which this package depends on.
        .target(
            name: "HaishinKit",
            dependencies: [])
    ]
    
)
