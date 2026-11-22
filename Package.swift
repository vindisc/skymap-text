// swift-tools-version: 6.0
import PackageDescription

// SPM restructure (branch `spm`): the app builds as a plain SwiftPM
// executable; the storyboard project lives on `main` only.
let package = Package(
    name: "SkyBook",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "SkyBook", targets: ["SkyBook"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.8.0"),
        .package(url: "https://github.com/raspu/Highlightr.git", from: "2.3.0"),
        .package(url: "https://github.com/stackotter/swift-cmark-gfm", from: "1.0.2"),
        // Vendored under Packages/KeyboardShortcuts: upstream's `#Preview`
        // macros require Xcode's PreviewsMacros plugin, absent from plain
        // `swift build` with Command Line Tools. Patched with canImport guards.
        .package(path: "Packages/KeyboardShortcuts"),
        .package(url: "https://github.com/simonbs/Prettier.git", from: "0.2.1"),
        .package(path: "Packages/MiaoYanCore"),
    ],
    targets: [
        .executableTarget(
            name: "SkyBook",
            dependencies: [
                "MiaoYanCore",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "Highlightr", package: "Highlightr"),
                .product(name: "CMarkGFM", package: "swift-cmark-gfm"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Prettier", package: "Prettier"),
                .product(name: "PrettierMarkdown", package: "Prettier"),
            ],
            path: "Sources/SkymapText",
            // Matches the storyboard project's SWIFT_VERSION 5; strict Swift 6
            // concurrency would otherwise flag the legacy AppKit code paths.
            // -enable-testing makes @testable imports work for the audit
            // executable, which SwiftPM only enables for .testTarget builds.
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-enable-testing"]),
            ]
        ),
    ]
)
