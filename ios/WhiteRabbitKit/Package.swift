// swift-tools-version: 5.9
import PackageDescription

// WhiteRabbitKit is the dependency-free, unit-tested E2E crypto core (X3DH +
// Double Ratchet on CryptoKit). The app target adds networking/UI on top.
let package = Package(
    name: "WhiteRabbitKit",
    platforms: [
        .iOS(.v16),
        .macOS(.v13),
    ],
    products: [
        .library(name: "WhiteRabbitKit", targets: ["WhiteRabbitKit"]),
    ],
    targets: [
        .target(name: "WhiteRabbitKit"),
        .testTarget(
            name: "WhiteRabbitKitTests",
            dependencies: ["WhiteRabbitKit"]
        ),
    ]
)
