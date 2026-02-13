// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BarPin",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "BarPinCore", targets: ["BarPinCore"]),
        .executable(name: "BarPinCoreChecks", targets: ["BarPinCoreChecks"]),
        .executable(name: "BarPin", targets: ["BarPin"])
    ],
    targets: [
        .target(
            name: "BarPinCore",
            path: "Sources/BarPinCore"
        ),
        .executableTarget(
            name: "BarPinCoreChecks",
            dependencies: ["BarPinCore"],
            path: "Sources/BarPinCoreChecks"
        ),
        .executableTarget(
            name: "BarPin",
            dependencies: ["BarPinCore"],
            path: "Sources/BarPin"
        )
    ]
)
