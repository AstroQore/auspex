# Changelog

All notable changes to Auspex are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Auspex is pre-alpha; there are no released versions yet.

## [Unreleased]

### Added

- SwiftPM package scaffold: `AuspexCore` library on GRDB 7 and the
  `AuspexApp` SwiftUI executable, both in Swift 6 language mode.
- `AuspexPaths` — single source of truth for the `~/.auspex/` tree, created
  lazily with mode 0700, with an injectable home directory for tests and a
  containment check that refuses to create anything outside its base.
- `AuspexStore` — GRDB store with a `DatabaseMigrator` scaffold whose
  `v1_initial` migration creates a `meta` key/value table.
- Empty main window (`NavigationSplitView` with Live / Projects / Tasks /
  Harnesses / Settings) and a menu bar extra with Open and Quit.
- `--mcp-stdio` and `--hook` command-line placeholders, dispatched before
  AppKit starts; both exit 2 until M3.
- `Scripts/build_app.sh` — packages and ad-hoc signs `.build/Auspex.app`, and
  fails the build if the signed bundle claims the app-sandbox entitlement.
- Open-source scaffolding: README (English and Chinese), architecture notes,
  contributor and security policies, issue and PR templates, and CI.
