// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SoundCtl",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .target(
            name: "CDDC",
            path: "Sources/CDDC"
        ),
        .target(
            name: "SoundCtlCore",
            dependencies: ["CDDC"],
            path: "Sources/SoundCtlCore",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("IOKit"),
                .linkedFramework("CoreFoundation")
            ]
        ),
        .executableTarget(
            name: "SoundCtl",
            dependencies: ["SoundCtlCore"],
            path: "Sources/SoundCtl"
        )
    ]
)
