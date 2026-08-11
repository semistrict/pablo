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
    targets: [
        .target(
            name: "PabloCore",
            path: "Sources/Pablo",
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
            linkerSettings: [.linkedFramework("AVKit")]
        ),
        .testTarget(name: "PabloTests", dependencies: ["PabloCore"]),
    ],
    swiftLanguageModes: [.v5]
)
