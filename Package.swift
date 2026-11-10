// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "BeyondClone",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BeyondClone",
            path: "Sources/BeyondClone",
            swiftSettings: [.unsafeFlags(["-swift-version", "5"])],
            linkerSettings: [.linkedFramework("NetFS")]
        )
    ]
)
