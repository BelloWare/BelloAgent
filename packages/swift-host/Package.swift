// swift-tools-version: 5.10
import PackageDescription
let package = Package(
    name: "PiNativeHost",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "pi-native-host", targets: ["PiHost"]), .library(name: "PiAgentCore", targets: ["PiAgentCore"])],
    targets: [.target(name: "PiAgentCore"), .executableTarget(name: "PiHost", dependencies: ["PiAgentCore"]), .testTarget(name: "PiAgentCoreTests", dependencies: ["PiAgentCore"])],
    swiftLanguageVersions: [.v5]
)
