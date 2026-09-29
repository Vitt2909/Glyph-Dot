// swift-tools-version:6.0
// Glyph — uma criatura-agente open source que vive no desktop do macOS.
//
// GlyphCore e glyphd compilam em Linux (só Foundation).
// GlyphBody e o app só existem no macOS (AppKit / QuartzCore).

import PackageDescription

var products: [Product] = [
    .library(name: "GlyphCore", targets: ["GlyphCore"]),
    .library(name: "GlyphDaemon", targets: ["GlyphDaemon"]),
    .executable(name: "glyphd", targets: ["glyphd"]),
]

var targets: [Target] = [
    .target(
        name: "GlyphCore",
        path: "Sources/GlyphCore"
    ),
    .target(
        name: "GlyphDaemon",
        dependencies: ["GlyphCore"],
        path: "Sources/GlyphDaemon"
    ),
    .executableTarget(
        name: "glyphd",
        dependencies: ["GlyphCore", "GlyphDaemon"],
        path: "Sources/glyphd"
    ),
    .testTarget(
        name: "GlyphCoreTests",
        dependencies: ["GlyphCore"],
        path: "Tests/GlyphCoreTests"
    ),
]

#if os(macOS)
products.append(.library(name: "GlyphBody", targets: ["GlyphBody"]))
products.append(.executable(name: "Glyph", targets: ["GlyphApp"]))
targets.append(contentsOf: [
    .target(
        name: "GlyphBody",
        dependencies: ["GlyphCore"],
        path: "Sources/GlyphBody"
    ),
    .executableTarget(
        name: "GlyphApp",
        dependencies: ["GlyphBody", "GlyphCore"],
        path: "Sources/GlyphApp"
    ),
])
#endif

let package = Package(
    name: "Glyph",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v6]
)
