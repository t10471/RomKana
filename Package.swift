// swift-tools-version: 6.1
import PackageDescription

let package = Package(
    name: "RomKana",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(
            url: "https://github.com/azooKey/AzooKeyKanaKanjiConverter",
            .upToNextMinor(from: "0.8.0"),
            traits: ["Zenzai"]
        )
    ],
    targets: [
        .executableTarget(
            name: "RomKana",
            dependencies: [
                .product(
                    name: "KanaKanjiConverterModuleWithDefaultDictionary",
                    package: "AzooKeyKanaKanjiConverter"
                )
            ],
            path: "Sources",
            swiftSettings: [.interoperabilityMode(.Cxx), .swiftLanguageMode(.v5)]
        )
    ]
)
