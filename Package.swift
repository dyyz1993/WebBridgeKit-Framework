// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "WebBridgeKit",
    defaultLocalization: "zh-Hans",
    platforms: [
        .iOS(.v15)
    ],
    products: [
        .library(
            name: "WebBridgeKit",
            targets: ["WebBridgeKit"]
        ),
        .library(
            name: "WBKMessage",
            targets: ["WBKMessage"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/SnapKit/SnapKit.git", from: "5.7.0"),
        .package(url: "https://github.com/ReactiveX/RxSwift.git", from: "6.6.0"),
        .package(url: "https://github.com/RxSwiftCommunity/RxDataSources.git", from: "5.0.0"),
        .package(url: "https://github.com/Moya/Moya.git", from: "15.0.0"),
        .package(url: "https://github.com/scinfu/SwiftSoup.git", from: "2.6.0"),
        .package(url: "https://github.com/realm/realm-swift.git", from: "10.42.0"),
        .package(url: "https://github.com/weichsel/ZIPFoundation.git", from: "0.9.0")
    ],
    targets: [
        .target(
            name: "WBKMessage",
            path: "Sources/Message"
        ),
        .target(
            name: "WebBridgeKit",
            dependencies: [
                "WBKMessage",
                "SnapKit",
                .product(name: "RxSwift", package: "RxSwift"),
                .product(name: "RxCocoa", package: "RxSwift"),
                "RxDataSources",
                .product(name: "RxMoya", package: "Moya"),
                "SwiftSoup",
                .product(name: "RealmSwift", package: "realm-swift"),
                "ZIPFoundation"
            ],
            path: "Sources",
            exclude: ["Message"],
            resources: [
                .process("../Resources/WebBridge.js"),
                .process("../Resources/PrivacyInfo.xcprivacy")
            ]
        )
    ]
)
