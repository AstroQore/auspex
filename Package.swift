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
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        // AgentSessionKit / AgentSessionLive provide the harness source
        // adapters, the AgentEvent model, and the live tailing pipeline.
        // TODO: switch to the git URL once agent-session-kit is published and
        // tagged; a path dependency is only workable while the two packages
        // are checked out side by side.
        .package(path: "../agent-session-kit")
    ],
    targets: [
        .executableTarget(
            name: "AuspexApp",
            dependencies: [
                "AuspexCore",
                // The view layer renders `SessionSnapshot`, `SessionState`,
                // and `Harness` directly, and `AppEnvironment` builds the
                // ingest pipeline out of `AgentSessionLive` types. Importing
                // AuspexCore does not re-export them, so both products are
                // named here as well.
                .product(name: "AgentSessionKit", package: "agent-session-kit"),
                .product(name: "AgentSessionLive", package: "agent-session-kit")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .target(
            name: "AuspexCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "AgentSessionKit", package: "agent-session-kit"),
                .product(name: "AgentSessionLive", package: "agent-session-kit")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AuspexCoreTests",
            dependencies: [
                "AuspexCore",
                .product(name: "AgentSessionKit", package: "agent-session-kit"),
                .product(name: "AgentSessionLive", package: "agent-session-kit")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)]
        )
    ]
)
