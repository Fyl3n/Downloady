// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Dropload",
    platforms: [.macOS(.v14)],
    products: [
        // A droplet is a loadable bundle, so its product is a dynamic library.
        // Do not make it static: the app already carries DroppyKit, and a
        // second copy inside the droplet gives the same type two metadata
        // records, which fails every cast between them.
        .library(name: "Dropload", type: .dynamic, targets: ["Dropload"])
    ],
    dependencies: [
        .package(url: "https://gitlab.com/droppyformac1/droppykit.git", from: "1.8.0")
    ],
    targets: [
        .target(
            name: "Dropload",
            dependencies: [.product(name: "DroppyKit", package: "droppykit")]
        ),
        .executableTarget(
            name: "DroploadHarness",
            dependencies: [
                "Dropload",
                .product(name: "DroppyKitHarness", package: "droppykit")
            ]
        ),
        // Unit tests for the pure logic (option mapping, metadata decoding,
        // browser table). `droppykit build` compiles only the Dropload target,
        // so this never reaches the bundle.
        .testTarget(
            name: "DroploadTests",
            dependencies: ["Dropload"]
        )
    ]
)
