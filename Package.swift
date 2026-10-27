// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DiskCare",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "DiskCareCore", targets: ["DiskCareCore"]),
        .executable(name: "diskcare", targets: ["diskcare"]),
        .executable(name: "DiskCareApp", targets: ["DiskCareApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
    ],
    targets: [
        .target(name: "DiskCareCore"),
        .executableTarget(
            name: "diskcare",
            dependencies: [
                "DiskCareCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "DiskCareApp", dependencies: ["DiskCareCore"]),
        .testTarget(name: "DiskCareCoreTests", dependencies: ["DiskCareCore"]),
    ]
)
