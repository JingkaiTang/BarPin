// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "BarPin",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "BarPin", targets: ["BarPin"])
    ],
    targets: [
        .executableTarget(
            name: "BarPin",
            path: "Sources/BarPin"
        )
    ]
)
