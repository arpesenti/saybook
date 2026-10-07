// swift-tools-version: 6.0
import PackageDescription

// Warnings are errors, always. A warning in a green build is a warning nobody
// reads — ticket 15 is the worked example: an unreachable `catch` and an inert
// `try` sat in this package, printing on every production build, until they
// were noticed by hand, and they were describing a real swallowed error.
//
// `unsafeFlags` is the only way to make this the package's own default rather
// than a flag every invocation has to remember (`swift build -Xswiftc …`,
// `swift test -Xswiftc …`, and whatever a future script does). The cost is that
// SwiftPM refuses to let another package depend on this one; saybook is a
// standalone executable with no dependents, so that is not a loss here.
let warningsAsErrors: [SwiftSetting] = [
    .unsafeFlags(["-warnings-as-errors"])
]

// The same policy for the C++ bridge. `-Werror` alone would only promote the
// warnings clang already enables, which is very few: `-Wall -Wextra` is what
// makes a plain unused variable reachable, verified by adding one and watching
// this target fail. The bridge is clean under the full set.
let cWarningsAsErrors: [CSetting] = [
    .unsafeFlags(["-Wall", "-Wextra", "-Werror"])
]

let package = Package(
    name: "saybook",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "saybook",
            dependencies: ["SaybookCore"],
            swiftSettings: warningsAsErrors
        ),
        .target(
            name: "SaybookCore",
            dependencies: ["SiriTTSBridge"],
            swiftSettings: warningsAsErrors
        ),
        // The private Siri speech engine has no public API and no Swift
        // access: it is a C++ class reached through dlopen/dlsym. The header
        // is pure C, so SaybookCore imports this target without C++
        // interoperability enabled.
        .target(
            name: "SiriTTSBridge",
            publicHeadersPath: "include",
            cSettings: cWarningsAsErrors
        ),
        .testTarget(
            name: "SaybookTests",
            dependencies: ["SaybookCore"],
            exclude: ["Fixtures"],
            swiftSettings: warningsAsErrors
        ),
    ]
)
