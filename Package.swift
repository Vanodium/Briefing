// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Briefing",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Updates from GitHub Releases (appcast + EdDSA-signed archives).
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.10.0"),
    ],
    targets: [
        .executableTarget(
            name: "Briefing",
            dependencies: [.product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/Briefing",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("EventKit"),
                .linkedFramework("Carbon"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("Network"),
                .linkedFramework("Security"),
                // Sparkle.framework is copied into Contents/Frameworks by build.sh.
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        )
    ]
)
