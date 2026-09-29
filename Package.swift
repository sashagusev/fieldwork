// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Fieldwork",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Fieldwork", targets: ["Fieldwork"]),
        .executable(name: "fieldwork-cli", targets: ["FieldworkCLI"])
    ],
    targets: [
        .target(name: "ResearchCore"),
        .executableTarget(name: "Fieldwork", dependencies: ["ResearchCore"]),
        .executableTarget(name: "FieldworkCLI", dependencies: ["ResearchCore"]),
        .testTarget(name: "ResearchCoreTests", dependencies: ["ResearchCore"])
    ]
)
