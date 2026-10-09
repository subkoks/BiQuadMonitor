// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "BiQuadMonitor",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "BiQuadMonitor", targets: ["BiQuadMonitor"]), .library(name: "SignalCore", targets: ["SignalCore"]), .library(name: "SessionStore", targets: ["SessionStore"])],
    targets: [
        .target(name: "SignalCore"),
        .target(name: "CFileLock"),
        .target(name: "SessionStore", dependencies: ["SignalCore", "CFileLock"], linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "BiQuadMonitor", dependencies: ["SignalCore", "SessionStore"]),
        .testTarget(name: "SignalCoreTests", dependencies: ["SignalCore"]),
        .testTarget(name: "SessionStoreTests", dependencies: ["SessionStore", "SignalCore"]),
        .testTarget(name: "RouterClientTests", dependencies: ["BiQuadMonitor", "SignalCore"], resources: [.copy("Fixtures")])
    ]
)
