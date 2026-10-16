// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuotaPeek",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "QuotaPeek", targets: ["QuotaPeek"]), .executable(name: "quota-peek", targets: ["QuotaPeekCLI"])],
    targets: [
        .target(name: "QuotaCore"),
        .executableTarget(name: "QuotaPeek", dependencies: ["QuotaCore"]),
        .executableTarget(name: "QuotaPeekCLI", dependencies: ["QuotaCore"]),
        .testTarget(name: "QuotaCoreTests", dependencies: ["QuotaCore"])
    ],
    swiftLanguageModes: [.v5]
)
