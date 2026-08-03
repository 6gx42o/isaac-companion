// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "IsaacCompanion",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IsaacCore"),
        .target(name: "Ingest", dependencies: ["IsaacCore"]),
        // Room geometry and sprite matching. A library rather than part of the app so
        // tests can import it -- while it lived in the executable target the only way to
        // "test" it was to keep a second copy of the arithmetic in the test file, which
        // passed no matter what the real code did.
        .target(name: "IsaacVision"),
        .executableTarget(name: "ingestctl", dependencies: ["Ingest", "IsaacCore", "IsaacVision"]),
        .executableTarget(
            name: "IsaacCompanionApp",
            dependencies: ["IsaacCore", "Ingest", "IsaacVision"],
            resources: [.copy("Web"), .copy("VendoredData")]),
        .testTarget(name: "IsaacCoreTests", dependencies: ["IsaacCore"]),
        .testTarget(name: "IngestTests", dependencies: ["Ingest", "IsaacCore"]),
        .testTarget(name: "IsaacVisionTests", dependencies: ["IsaacVision"]),
    ]
)
