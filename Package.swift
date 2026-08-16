// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Pablo",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "PabloCore", targets: ["PabloCore"]),
        .executable(name: "pablo", targets: ["PabloCLI"]),
        .executable(name: "PabloApp", targets: ["PabloApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-protobuf.git", exact: "1.38.1"),
    ],
    targets: [
        .target(
            name: "PabloCore",
            dependencies: [
                .product(name: "SwiftProtobuf", package: "swift-protobuf"),
            ],
            path: "Sources/Pablo",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("ScreenCaptureKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .executableTarget(
            name: "PabloCLI",
            dependencies: ["PabloCore"],
            path: "Sources/PabloCLI"
        ),
        .executableTarget(
            name: "PabloApp",
            dependencies: ["PabloCore"],
            path: "Sources/PabloApp",
            resources: [.process("Resources")],
            linkerSettings: [
                .linkedFramework("AVKit"),
                .linkedFramework("SafariServices"),
                .linkedFramework("WebKit"),
            ]
        ),
        .testTarget(name: "PabloTests", dependencies: ["PabloCore", "PabloApp"]),
    ],
    swiftLanguageModes: [.v5]
)
