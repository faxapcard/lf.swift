// swift-tools-version:4.0
import PackageDescription

let package = Package(
    name: "HaishinKit",
    dependencies: [
        .Package(url: "https://github.com/shogo4405/Logboard.git", majorVersion: 1)
    ]
)
