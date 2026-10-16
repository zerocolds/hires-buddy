// swift-tools-version:6.1
import PackageDescription

let package = Package(
    name: "HiResBuddy",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "LDACEncoder", targets: ["LDACEncoder"]),
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
    ]
)
