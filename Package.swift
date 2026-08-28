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
        //
        // Pinned to an exact tag rather than a range or a sibling path:
        // `Package.resolved` is gitignored, so a release built from a clean
        // checkout of a tag has nothing else to tell it which kit to compile
        // in. The pin *is* the record of what shipped. Bump it deliberately;
        // `.github/workflows/bump-agent-session-kit.yml` opens the pull
        // request when the kit publishes a newer release, and merges nothing.
        //
        // To develop the two side by side, put the kit in edit mode instead of
        // editing this line — see AGENTS.md § 3.1.
        .package(url: "https://github.com/AstroQore/agent-session-kit.git", exact: "0.6.2"),
        // Sparkle is the standard update framework for independently
        // distributed macOS apps. Pinned to the exact reviewed release:
        // verifying and installing an update is the one thing this app does
        // that can replace its own binary.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.4")
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
                .product(name: "AgentSessionLive", package: "agent-session-kit"),
                // Only the app links Sparkle. Core stays free of it so the
                // update *policy* — which channel, what that means — can be
                // tested without a framework that wants a bundle.
                .product(name: "Sparkle", package: "Sparkle")
            ],
            // The vendor marks every surface identifies a harness with.
            // `.copy` rather than `.process`: these are already the exact
            // bytes to ship, the directory structure is what `HarnessLogo`
            // looks them up by, and `build_app.sh` moves the whole
            // `Auspex_AuspexApp.bundle` into `Contents/Resources` before
            // signing.
            resources: [
                .copy("Resources/ProviderIcons"),
                .copy("Resources/Brand"),
                // Versioned, on-demand agent playbooks. The installer reads
                // these from the shipped app resource bundle and writes them
                // only after a person clicks the corresponding setup row.
                .copy("Resources/Skills")
            ],
            swiftSettings: [.swiftLanguageMode(.v6)],
            // Sparkle ships as a framework, and `build_app.sh` puts it where
            // every other macOS app keeps one: `Contents/Frameworks`. Without
            // this rpath the packaged binary looks only where SwiftPM left the
            // artifact, which is a path that does not exist on a user's Mac.
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Frameworks"])
            ]
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
            name: "AuspexAppTests",
            dependencies: [
                "AuspexApp",
                "AuspexCore",
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
