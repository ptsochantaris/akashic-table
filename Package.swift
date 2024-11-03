// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "AkashicTable",
    products: [
        .library(
            name: "AkashicTable",
            targets: ["AkashicTable"]
        ),
    ],
    targets: [
        .target(
            name: "AkashicTable"),
        .testTarget(
            name: "AkashicTableTests",
            dependencies: ["AkashicTable"]
        ),
    ]
)
