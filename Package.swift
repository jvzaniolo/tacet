// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MenuShelf",
    platforms: [.macOS("27.0")],
    targets: [
        .executableTarget(
            name: "MenuShelf",
            path: "Sources/MenuShelf",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
            ]
        ),
    ]
)
