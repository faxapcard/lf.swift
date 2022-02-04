// swift-tools-version:5.4.0
import PackageDescription

let package = Package(
    name: "HaishinKit",
    platforms: [
        .macOS(.v10_15),
    ],
    dependencies: [
        .package(url: "https://github.com/shogo4405/Logboard.git", from: "1.0.0"),
    ]
)
