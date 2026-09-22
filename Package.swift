// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Downloady",
    platforms: [.macOS(.v14)],
    products: [
        // A droplet is a loadable bundle, so its product is a dynamic library.
        // Do not make it static: the app already carries DroppyKit, and a
        // second copy inside the droplet gives the same type two metadata
        // records, which fails every cast between them.
        .library(name: "Downloady", type: .dynamic, targets: ["Downloady"])
    ],
    dependencies: [
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.9.0")
    ],
    targets: [
        .target(
            name: "Downloady",
            dependencies: [.product(name: "DroppyKit", package: "droppykit")]
        ),
        .executableTarget(
            name: "DownloadyHarness",
            dependencies: [
                "Downloady",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ]
        ),
        // Unit tests for the pure logic (option mapping, metadata decoding,
        // browser table). `droppykit build` compiles only the Downloady target,
        // so this never reaches the bundle.
        .testTarget(
            name: "DownloadyTests",
            dependencies: ["Downloady"]
        )
    ]
)
