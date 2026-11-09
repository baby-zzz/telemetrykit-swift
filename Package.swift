// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "telemetrykit-swift",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "TelemetryKit", targets: ["TelemetryKit"]),
    ],
    targets: [
        .target(name: "TelemetryKit"),
        .testTarget(name: "TelemetryKitTests", dependencies: ["TelemetryKit"]),
    ],
    swiftLanguageModes: [.v6]
)
