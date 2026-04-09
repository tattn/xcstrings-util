// swift-tools-version: 6.3
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "xcstrings-util",
    platforms: [
        .macOS(.v13),
    ],
    products: [
        .library(
            name: "XCStringsUtilCore",
            targets: ["XCStringsUtilCore"]
        ),
        .executable(
            name: "xcstrings-util",
            targets: ["xcstrings-util"]
        ),
    ],
    targets: [
        .target(
            name: "XCStringsUtilCore"
        ),
        .executableTarget(
            name: "xcstrings-util",
            dependencies: ["XCStringsUtilCore"]
        ),
        .testTarget(
            name: "XCStringsUtilCoreTests",
            dependencies: ["XCStringsUtilCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
