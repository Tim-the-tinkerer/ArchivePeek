// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ArchivePeek",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "ArchivePeek", targets: ["ArchivePeek"]),
    ],
    targets: [
        .executableTarget(
            name: "ArchivePeek",
            path: "Sources/ArchivePeek",
            linkerSettings: [
                .linkedFramework("QuickLook"),
                .linkedFramework("QuickLookUI"),
            ]
        ),
    ]
)