// swift-tools-version:4.2

import PackageDescription

let package = Package(
    name: "HaishinKit",
    
    products: [
        .library(name: "HaishinKit", targets: ["HaishinKit"]),
    ],
    dependencies: [
        .package(url: "https://github.com/shogo4405/Logboard.git", from: "1.0.0"),
    ]
    
)
