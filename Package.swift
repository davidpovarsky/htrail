// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HTTrail",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        .library(name: "HTTrailCore", targets: ["HTTrailCore"]),
        .executable(name: "HTTrail", targets: ["HTTrail"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/apple/swift-nio-ssl.git", from: "2.27.0"),
        .package(url: "https://github.com/apple/swift-certificates.git", from: "1.5.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
        .package(url: "https://github.com/apple/swift-asn1.git", from: "1.1.0")
    ],
    targets: [
        .target(
            name: "HTTrailCore",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOSSL", package: "swift-nio-ssl"),
                .product(name: "X509", package: "swift-certificates"),
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "_CryptoExtras", package: "swift-crypto"),
                .product(name: "SwiftASN1", package: "swift-asn1")
            ],
            // NIO ChannelHandlers are event-loop confined and intentionally
            // non-Sendable; Swift 5 language mode avoids fighting that design.
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "HTTrail",
            dependencies: ["HTTrailCore"]
        ),
        .testTarget(
            name: "HTTrailCoreTests",
            dependencies: ["HTTrailCore"]
        )
    ]
)
