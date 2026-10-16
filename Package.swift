// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "HiResBuddy",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LDACEncoder", targets: ["LDACEncoder"]),
        .library(name: "BTStream", targets: ["BTStream"]),
        .library(name: "HiResBuddyCore", targets: ["HiResBuddyCore"]),
    ],
    targets: [
        .target(
            name: "CLDAC",
            cSettings: [
                .headerSearchPath("../../third_party/libldac/src"),
                .headerSearchPath("../../third_party/libldac/inc"),
            ]
        ),
        .target(name: "LDACEncoder", dependencies: ["CLDAC"]),
        .testTarget(name: "LDACEncoderTests", dependencies: ["LDACEncoder"]),
        .target(
            name: "BTStream",
            linkerSettings: [.linkedFramework("IOBluetooth"), .linkedFramework("CoreBluetooth")]
        ),
        .executableTarget(
            name: "hiresbuddy-transport",
            dependencies: ["BTStream"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/hiresbuddy-transport/Info.plist",
            ])]
        ),
        // Test-only stand-in for the helper (no Bluetooth); deliberately not a product.
        .executableTarget(name: "fake-transport", path: "Tests/fake-transport"),
        .testTarget(name: "BTStreamTests", dependencies: ["BTStream", "fake-transport"], path: "Tests/BTStreamTests"),
        .target(name: "HiResBuddyCore", dependencies: ["LDACEncoder", "BTStream"]),
        .executableTarget(
            name: "hiresbuddy-cli",
            dependencies: ["HiResBuddyCore", "BTStream", "LDACEncoder"],
            exclude: ["Info.plist"],
            linkerSettings: [.unsafeFlags([
                "-Xlinker", "-sectcreate", "-Xlinker", "__TEXT", "-Xlinker", "__info_plist",
                "-Xlinker", "Sources/hiresbuddy-cli/Info.plist",
            ])]
        ),
        .testTarget(name: "HiResBuddyCoreTests", dependencies: ["HiResBuddyCore", "LDACEncoder"]),
        // The menu bar app; scripts/bundle.sh wraps it (with Resources/Info.plist) into build/HiResBuddy.app.
        .executableTarget(name: "HiResBuddy", dependencies: ["HiResBuddyCore", "LDACEncoder"], exclude: ["Resources"]),
    ]
)
