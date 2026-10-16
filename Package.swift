// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Tacet",
    defaultLocalization: "en",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "Tacet",
            path: "Sources/Tacet",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
