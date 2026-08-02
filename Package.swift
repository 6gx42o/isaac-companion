// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "IsaacCompanion",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "IsaacCore"),
        .target(name: "Ingest", dependencies: ["IsaacCore"]),
        .executableTarget(name: "ingestctl", dependencies: ["Ingest", "IsaacCore"]),
        .executableTarget(
            name: "IsaacCompanionApp",
            dependencies: ["IsaacCore", "Ingest"],
            resources: [.copy("Web"), .copy("VendoredData")]),
        .testTarget(name: "IsaacCoreTests", dependencies: ["IsaacCore"]),
        .testTarget(name: "IngestTests", dependencies: ["Ingest", "IsaacCore"]),
    ]
)
