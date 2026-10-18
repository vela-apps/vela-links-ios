// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "VelaLinks",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
    ],
    products: [
        .library(name: "VelaLinks", targets: ["VelaLinks"]),
    ],
    targets: [
        .target(name: "VelaLinks", resources: [.process("PrivacyInfo.xcprivacy")]),
        .testTarget(name: "VelaLinksTests", dependencies: ["VelaLinks"]),
    ]
)
