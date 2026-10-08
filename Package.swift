// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "BiQuadMonitor", platforms: [.macOS(.v13)], products: [.executable(name: "BiQuadMonitor", targets: ["BiQuadMonitor"])], targets: [.target(name: "SignalCore"), .executableTarget(name: "BiQuadMonitor", dependencies: ["SignalCore"]), .testTarget(name: "SignalCoreTests", dependencies: ["SignalCore"]), .testTarget(name: "RouterClientTests", dependencies: ["BiQuadMonitor", "SignalCore"], resources: [.copy("Fixtures")])])
