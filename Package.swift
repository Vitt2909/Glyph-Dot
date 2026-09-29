// swift-tools-version:6.0
// Glyph — uma criatura-agente open source que vive no desktop do macOS.
//
// GlyphCore e glyphd compilam em Linux (só Foundation).
// GlyphBody e o app só existem no macOS (AppKit / QuartzCore).

import PackageDescription

var products: [Product] = [
    .library(name: "GlyphCore", targets: ["GlyphCore"]),
    .library(name: "GlyphIPC", targets: ["GlyphIPC"]),
    .library(name: "GlyphDaemon", targets: ["GlyphDaemon"]),
    .executable(name: "glyphd", targets: ["glyphd"]),
    .executable(name: "glyph-art", targets: ["glyph-art"]),
]

var targets: [Target] = [
    .target(
        name: "GlyphCore",
        path: "Sources/GlyphCore"
    ),
    .target(
        name: "GlyphIPC",
        dependencies: ["GlyphCore"],
        path: "Sources/GlyphIPC"
    ),
    .target(
        name: "GlyphDaemon",
        dependencies: ["GlyphCore", "GlyphIPC"],
        path: "Sources/GlyphDaemon"
    ),
    .executableTarget(
        name: "glyphd",
        dependencies: ["GlyphCore", "GlyphIPC", "GlyphDaemon"],
        path: "Sources/glyphd"
    ),
    .executableTarget(
        name: "glyph-art",
        dependencies: ["GlyphCore"],
        path: "Sources/glyph-art"
    ),
    .testTarget(
        name: "GlyphCoreTests",
        dependencies: ["GlyphCore"],
        path: "Tests/GlyphCoreTests"
    ),
    .testTarget(
        name: "GlyphDaemonTests",
        dependencies: ["GlyphCore", "GlyphIPC", "GlyphDaemon"],
        path: "Tests/GlyphDaemonTests"
    ),
]

#if os(macOS)
products.append(.library(name: "GlyphBody", targets: ["GlyphBody"]))
products.append(.executable(name: "Glyph", targets: ["GlyphApp"]))
targets.append(contentsOf: [
    .target(
        name: "GlyphBody",
        dependencies: ["GlyphCore", "GlyphIPC"],
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
