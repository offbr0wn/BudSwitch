// swift-tools-version: 5.9
import PackageDescription

// SPM rather than a hand-listed swiftc invocation: the Galaxy Buds UI ships localisation
// bundles and an Info.plist that need resource processing, and a whole-directory target
// means new files no longer require a build script edit.
let package = Package(
    name: "BudSwitch",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "BudSwitch",
            path: "Sources",
            resources: [.process("Resources")]
        )
    ]
)
