// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Auspex",
    platforms: [
        .macOS(.v26)
    ],
    products: [
        .executable(name: "Auspex", targets: ["AuspexApp"]),
        .library(name: "AuspexCore", targets: ["AuspexCore"])
    ],
    dependencies: [
        // GRDB backs the local session/event store under ~/.auspex/auspex.db.
        // FTS5 full-text search over transcripts is planned for M1.
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
        // AgentSessionKit / AgentSessionLive provide the harness source
        // adapters, the AgentEvent model, and the live tailing pipeline.
        // The sibling package is still being written; wiring it up is M0-4.
        // .package(path: "../agent-session-kit"),  // enabled in M0-4
    ],
    targets: [
        .executableTarget(
            name: "AuspexApp",
            dependencies: [
                "AuspexCore"
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AuspexCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
                // .product(name: "AgentSessionKit", package: "agent-session-kit"),  // enabled in M0-4
                // .product(name: "AgentSessionLive", package: "agent-session-kit"),  // enabled in M0-4
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AuspexCoreTests",
            dependencies: ["AuspexCore"],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
