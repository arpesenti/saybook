// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "saybook",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "saybook",
            dependencies: ["SaybookCore"]
        ),
        .target(
            name: "SaybookCore"
        ),
        .testTarget(
            name: "SaybookTests",
            dependencies: ["SaybookCore"],
            exclude: ["Fixtures"]
        ),
    ]
)
