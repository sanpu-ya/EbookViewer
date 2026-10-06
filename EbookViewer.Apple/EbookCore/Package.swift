// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "EbookCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "EbookCore", targets: ["EbookCore"]),
    ],
    dependencies: [
        // RAR (CBR) の展開。unrar のソースを同梱した Swift Package
        .package(url: "https://github.com/mtgto/Unrar.swift", from: "0.5.4"),
    ],
    targets: [
        // Linux (テスト実行用) では zlib を直接リンクする。Apple では Compression framework を使う。
        .systemLibrary(name: "CZlib", path: "Sources/CZlib"),
        .target(
            name: "EbookCore",
            dependencies: [
                "CZlib",
                .product(name: "Unrar", package: "Unrar.swift"),
            ],
            path: "Sources/EbookCore",
            resources: [.copy("Resources/viewer.css"), .copy("Resources/viewer.js")]
        ),
        .testTarget(
            name: "EbookCoreTests",
            dependencies: ["EbookCore"],
            path: "Tests/EbookCoreTests",
            resources: [.copy("Samples")]
        ),
    ]
)
