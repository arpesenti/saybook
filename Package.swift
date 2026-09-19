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
            name: "SaybookCore",
            dependencies: ["SiriTTSBridge"]
        ),
        // The private Siri speech engine has no public API and no Swift
        // access: it is a C++ class reached through dlopen/dlsym. The header
        // is pure C, so SaybookCore imports this target without C++
        // interoperability enabled.
        .target(
            name: "SiriTTSBridge",
            publicHeadersPath: "include"
        ),
        .testTarget(
            name: "SaybookTests",
            dependencies: ["SaybookCore"],
            exclude: ["Fixtures"]
        ),
    ]
)
