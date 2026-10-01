// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ArchivePeek",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ArchivePeek", targets: ["ArchivePeek"]),
    ],
    targets: [
        .target(
            name: "ArchivePeekCore",
            path: "Sources/ArchivePeek",
            linkerSettings: [
                .linkedFramework("QuickLook"),
                .linkedFramework("QuickLookUI"),
            ]
        ),
        .executableTarget(
            name: "ArchivePeek",
            dependencies: ["ArchivePeekCore"],
            path: "Sources/ArchivePeekMain",
            linkerSettings: [
                .linkedFramework("QuickLook"),
                .linkedFramework("QuickLookUI"),
            ]
        ),
        .testTarget(
            name: "ArchivePeekTests",
            dependencies: ["ArchivePeekCore"],
            path: "Tests/ArchivePeekTests"
        ),
    ]
)