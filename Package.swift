// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GPTTranslator",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "GPTTranslator", targets: ["GPTTranslator"])
    ],
    targets: [
        .executableTarget(
            name: "GPTTranslator",
            path: "Sources/GPTTranslator"
        )
    ]
)
