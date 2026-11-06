// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Korrektor",
    platforms: [.macOS("27.0")],
    products: [
        .library(name: "KorrektorCore", targets: ["KorrektorCore"]),
        .executable(name: "korrektor", targets: ["korrektor"]),
        // Named KorrektorApp, not Korrektor: .build/release would otherwise hold
        // both "korrektor" and "Korrektor", which are the same file on a
        // case-insensitive volume — the app build silently overwrote the CLI.
        .executable(name: "KorrektorApp", targets: ["KorrektorUI"]),
    ],
    targets: [
        .target(name: "KorrektorCore"),
        .executableTarget(name: "korrektor", dependencies: ["KorrektorCore"]),
        .executableTarget(name: "KorrektorUI", dependencies: ["KorrektorCore"]),
        .testTarget(name: "KorrektorCoreTests", dependencies: ["KorrektorCore"]),
    ]
)
