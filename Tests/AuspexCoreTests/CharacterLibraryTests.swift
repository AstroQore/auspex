import AgentSessionKit
import AgentSessionLive
import Foundation
import Testing

@testable import AuspexCore

@Suite("Character manifests")
struct CharacterManifestTests {
    @Test("a full manifest decodes every documented field")
    func decodesFullManifest() throws {
        let json = """
        {
          "id": "claudeCode-default",
          "displayName": "Ember",
          "kind": "person",
          "harness": "claudeCode",
          "accent": "#E0785A",
          "cell": 32,
          "anchor": "bottomCenter",
          "poses": {
            "idle": {"frames": 2, "fps": 2},
            "typing": {"frames": 6, "fps": 12}
          }
        }
        """
        let manifest = try JSONDecoder().decode(
            CharacterManifest.self, from: Data(json.utf8)
        )

        #expect(manifest.id == "claudeCode-default")
        #expect(manifest.displayName == "Ember")
        #expect(manifest.kind == .person)
        #expect(manifest.boundHarness == .claudeCode)
        #expect(manifest.accent == "#E0785A")
        #expect(manifest.cell == 32)
        #expect(manifest.anchor == .bottomCenter)
        #expect(manifest.spec(for: .typing) == CharacterPoseSpec(frames: 6, fps: 12))
        #expect(manifest.spec(for: .typing)?.timePerFrame == 1.0 / 12)
        #expect(manifest.unknownPoseNames.isEmpty)
    }

    @Test("a minimal manifest takes the documented defaults")
    func decodesMinimalManifest() throws {
        let manifest = try JSONDecoder().decode(
            CharacterManifest.self, from: Data(#"{"id": "cat"}"#.utf8)
        )

        #expect(manifest.displayName == "cat")
        #expect(manifest.kind == .person)
        #expect(manifest.cell == CharacterManifest.defaultCell)
        #expect(manifest.anchor == .bottomCenter)
        #expect(manifest.harness == nil)
        #expect(manifest.poses.isEmpty)
    }

    @Test("a pet with a typo in kind is still a character")
    func unknownEnumeratedValuesFallBack() throws {
        let json = #"{"id": "cat", "kind": "feline", "anchor": "middle", "poses": {"idle": {}}}"#
        let manifest = try JSONDecoder().decode(CharacterManifest.self, from: Data(json.utf8))

        #expect(manifest.kind == .person)
        #expect(manifest.anchor == .bottomCenter)
        // A pose entry with no frame count is one frame at the default rate.
        #expect(manifest.spec(for: .idle) == CharacterPoseSpec(frames: 1, fps: 8))
    }

    @Test("pose names the scene does not draw survive decoding so they can be reported")
    func keepsUnknownPoseNames() throws {
        let json = #"{"id": "cat", "poses": {"idle": {"frames": 1}, "dancing": {"frames": 4}}}"#
        let manifest = try JSONDecoder().decode(CharacterManifest.self, from: Data(json.utf8))

        #expect(manifest.unknownPoseNames == ["dancing"])
    }

    @Test("a manifest round-trips through its own encoder")
    func roundTripsThroughEncoder() throws {
        let original = CharacterManifest(
            id: "codex-default",
            displayName: "Sable",
            kind: .pet,
            harness: "codex",
            accent: "#2DD4BF",
            cell: 48,
            poses: ["blocked": CharacterPoseSpec(frames: 2, fps: 2)]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(CharacterManifest.self, from: data)

        #expect(decoded == original)
    }
}

@Suite("Character library")
struct CharacterLibraryTests {
    private func makeLibrary(
        _ home: URL
    ) -> (CharacterLibrary, builtIn: URL, user: URL) {
        let builtIn = home.appendingPathComponent("bundle-characters", isDirectory: true)
        let user = AuspexPaths(homeDirectory: home).charactersDirectory
        try? FileManager.default.createDirectory(at: builtIn, withIntermediateDirectories: true)
        try? FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        return (
            CharacterLibrary(builtInDirectory: builtIn, userDirectory: user),
            builtIn: builtIn,
            user: user
        )
    }

    @Test("a well-formed package loads every strip it holds")
    func loadsAWellFormedPackage() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (library, builtIn, _) = makeLibrary(home)

        try CharacterFixtures.writePackage(
            in: builtIn,
            id: "claudeCode-default",
            displayName: "Ember",
            poses: ["idle": (2, 2), "blocked": (2, 2), "typing": (6, 12)]
        )

        let catalog = library.scan()
        let package = try #require(catalog.package(id: "claudeCode-default"))

        #expect(package.displayName == "Ember")
        #expect(package.source == .builtIn)
        #expect(package.harness == .claudeCode)
        #expect(package.cell == 32)
        #expect(package.poses.count == 3)
        #expect(package.file(for: .typing)?.frames == 6)
        #expect(package.file(for: .typing)?.fps == 12)
        #expect(package.isDrawable)
        #expect(!package.hasErrors)
        // The five core poses nobody drew are warnings, not errors.
        #expect(package.missingCorePoses.count == 5)
        #expect(package.problems.allSatisfy { $0.severity == .warning })
    }

    @Test("a user package with the same id replaces the built-in and says so")
    func userPackagesOverrideBuiltIns() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (library, builtIn, user) = makeLibrary(home)

        try CharacterFixtures.writePackage(in: builtIn, id: "codex-default", displayName: "Shipped")
        try CharacterFixtures.writePackage(in: builtIn, id: "cursor-default", displayName: "Kept")
        try CharacterFixtures.writePackage(in: user, id: "codex-default", displayName: "Mine")

        let catalog = library.scan()

        #expect(catalog.packages.count == 2)
        let codex = try #require(catalog.package(id: "codex-default"))
        #expect(codex.displayName == "Mine")
        #expect(codex.source == .user)
        #expect(catalog.package(id: "cursor-default")?.source == .builtIn)
        #expect(catalog.shadowed.map(\.displayName) == ["Shipped"])
    }

    @Test("a strip whose height is not the cell is an error, not a crash")
    func reportsAStripOfTheWrongHeight() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (library, _, user) = makeLibrary(home)

        let directory = try CharacterFixtures.writePackage(
            in: user, id: "broken", poses: ["idle": (2, 2)], writeStrips: false
        )
        try CharacterFixtures.writeStrip(
            to: directory.appendingPathComponent("idle.png"), cell: 32, frames: 2, height: 47
        )

        let package = try #require(library.scan().package(id: "broken"))

        #expect(package.hasErrors)
        #expect(!package.isDrawable)
        #expect(package.poses.isEmpty)
        let problem = try #require(package.problems.first { $0.severity == .error })
        #expect(problem.pose == "idle")
        #expect(problem.message.contains("64×47"))
    }

    @Test("a strip that is not a whole number of frames is an error")
    func reportsAStripOfTheWrongWidth() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (library, _, user) = makeLibrary(home)

        let directory = try CharacterFixtures.writePackage(
            in: user, id: "ragged", poses: ["idle": (2, 2)], writeStrips: false
        )
        // 70 columns of a 32-pixel cell: two frames and six stray pixels.
        try CharacterFixtures.writeStrip(
            to: directory.appendingPathComponent("idle.png"), cell: 35, frames: 2, height: 32
        )

        let package = try #require(library.scan().package(id: "ragged"))

        #expect(package.hasErrors)
        #expect(package.problems.contains { $0.severity == .error && $0.pose == "idle" })
    }

    @Test("the pixels win when the manifest disagrees about frame count")
    func measuredFramesBeatDeclaredFrames() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (library, _, user) = makeLibrary(home)

        let directory = try CharacterFixtures.writePackage(
            in: user, id: "stale-manifest", poses: ["typing": (4, 12)], writeStrips: false
        )
        try CharacterFixtures.writeStrip(
            to: directory.appendingPathComponent("typing.png"), cell: 32, frames: 6
        )

        let package = try #require(library.scan().package(id: "stale-manifest"))

        #expect(package.file(for: .typing)?.frames == 6)
        #expect(package.file(for: .typing)?.fps == 12)
        #expect(!package.hasErrors)
        #expect(
            package.problems.contains {
                $0.pose == "typing" && $0.message.contains("declares 4 frames")
            }
        )
    }

    @Test("a cell size the scene cannot place is an error")
    func reportsAnUnsupportedCell() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (library, _, user) = makeLibrary(home)

        try CharacterFixtures.writePackage(
            in: user, id: "huge", cell: 64, poses: ["idle": (2, 2)]
        )

        let package = try #require(library.scan().package(id: "huge"))

        #expect(package.hasErrors)
        #expect(package.problems.contains { $0.message.contains("cell is 64") })
    }

    @Test("48-pixel cells are as legal as 32-pixel ones")
    func acceptsTheLargerCell() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (library, _, user) = makeLibrary(home)

        try CharacterFixtures.writePackage(
            in: user, id: "tall", cell: 48, poses: ["idle": (2, 2)]
        )

        let package = try #require(library.scan().package(id: "tall"))

        #expect(!package.hasErrors)
        #expect(package.cell == 48)
        #expect(package.file(for: .idle)?.frames == 2)
    }

    @Test("a folder with strips but no manifest is listed with the reason")
    func reportsAMissingManifest() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (library, _, user) = makeLibrary(home)

        let directory = user.appendingPathComponent("no-manifest", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try CharacterFixtures.writeStrip(
            to: directory.appendingPathComponent("idle.png"), cell: 32, frames: 2
        )

        let package = try #require(library.scan().package(id: "no-manifest"))

        #expect(package.hasErrors)
        #expect(package.problems.contains { $0.message.contains("No character.json") })
    }

    @Test("a folder that is not a character package is ignored entirely")
    func ignoresUnrelatedFolders() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (library, _, user) = makeLibrary(home)

        try FileManager.default.createDirectory(
            at: user.appendingPathComponent("notes", isDirectory: true),
            withIntermediateDirectories: true
        )

        #expect(library.scan().packages.isEmpty)
    }

    @Test("corrupt JSON reports the reason instead of throwing")
    func reportsCorruptJSON() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (library, _, user) = makeLibrary(home)

        try CharacterFixtures.writePackage(
            in: user,
            id: "corrupt",
            poses: ["idle": (2, 2)],
            manifestOverride: "{ this is not json"
        )

        let package = try #require(library.scan().package(id: "corrupt"))

        #expect(package.hasErrors)
        #expect(package.problems.contains { $0.message.contains("character.json could not be read") })
    }

    @Test("a harness name nobody knows is a warning, not a rejection")
    func warnsAboutAnUnknownHarness() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let (library, _, user) = makeLibrary(home)

        try CharacterFixtures.writePackage(
            in: user, id: "orphan", harness: "notAHarness", poses: ["idle": (2, 2)]
        )

        let package = try #require(library.scan().package(id: "orphan"))

        #expect(!package.hasErrors)
        #expect(package.harness == nil)
        #expect(package.problems.contains { $0.message.contains("not a harness Auspex watches") })
    }

    @Test("the committed example package validates")
    func loadsTheCommittedFixture() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/Characters/example-default", isDirectory: true)
        let package = try #require(
            CharacterLibrary.load(packageAt: directory, source: .user)
        )

        #expect(package.id == "example-default")
        #expect(package.cell == 32)
        #expect(!package.hasErrors, "\(package.problems)")
        #expect(package.isDrawable)
        #expect(package.file(for: .blocked)?.frames == 2)
        #expect(package.file(for: .typing)?.frames == 6)
    }
}

@Suite("Character catalog")
struct CharacterCatalogTests {
    private func package(
        id: String,
        harness: Harness?,
        drawable: Bool = true
    ) -> CharacterPackage {
        CharacterPackage(
            manifest: CharacterManifest(
                id: id,
                displayName: id,
                harness: harness?.rawValue
            ),
            directory: URL(fileURLWithPath: "/tmp/\(id)"),
            source: .user,
            poses: drawable
                ? [
                    "idle": CharacterPackage.PoseFile(
                        name: "idle",
                        url: URL(fileURLWithPath: "/tmp/\(id)/idle.png"),
                        cell: 32,
                        frames: 1,
                        fps: 8
                    )
                ]
                : [:]
        )
    }

    @Test("a harness with no choice made takes the package that claims it")
    func fallsBackToTheClaimingPackage() {
        let catalog = CharacterCatalog(packages: [
            package(id: "codex-default", harness: .codex),
            package(id: "cursor-default", harness: .cursor)
        ])

        #expect(
            catalog.package(for: .codex, selection: CharacterSelection())?.id == "codex-default"
        )
        #expect(catalog.package(for: .grokBuild, selection: CharacterSelection()) == nil)
    }

    @Test("the conventional id wins when two packages claim one harness")
    func prefersTheConventionalID() {
        let catalog = CharacterCatalog(packages: [
            package(id: "codex-experiment", harness: .codex),
            package(id: "codex-default", harness: .codex)
        ])

        #expect(
            catalog.package(for: .codex, selection: CharacterSelection())?.id == "codex-default"
        )
    }

    @Test("a chosen character beats the one that claims the harness")
    func selectionBeatsTheClaim() {
        let catalog = CharacterCatalog(packages: [
            package(id: "codex-default", harness: .codex),
            package(id: "office-cat", harness: nil)
        ])
        var selection = CharacterSelection()
        selection.setCharacterID("office-cat", for: .codex)

        #expect(catalog.package(for: .codex, selection: selection)?.id == "office-cat")
    }

    @Test("a session override beats its harness's default")
    func sessionOverrideBeatsTheHarnessDefault() {
        let catalog = CharacterCatalog(packages: [
            package(id: "codex-default", harness: .codex),
            package(id: "office-cat", harness: nil)
        ])
        let key = SessionKey(harness: .codex, sessionID: "abc123")
        var selection = CharacterSelection()
        selection.setCharacterID("office-cat", for: key)

        #expect(catalog.package(for: key, selection: selection)?.id == "office-cat")
        #expect(catalog.package(for: .codex, selection: selection)?.id == "codex-default")
    }

    @Test("a chosen character that cannot be drawn is not chosen")
    func skipsAChosenPackageWithNoArt() {
        let catalog = CharacterCatalog(packages: [
            package(id: "codex-default", harness: .codex),
            package(id: "empty", harness: nil, drawable: false)
        ])
        var selection = CharacterSelection()
        selection.setCharacterID("empty", for: .codex)

        #expect(catalog.package(for: .codex, selection: selection)?.id == "codex-default")
    }

    @Test("every package with no harness is offered to every harness")
    func offersUnboundPackagesEverywhere() {
        let catalog = CharacterCatalog(packages: [
            package(id: "codex-default", harness: .codex),
            package(id: "office-cat", harness: nil)
        ])

        #expect(catalog.packages(for: .codex).map(\.id) == ["codex-default", "office-cat"])
        #expect(catalog.packages(for: .cursor).map(\.id) == ["office-cat"])
    }
}

@Suite("Character selection")
struct CharacterSelectionTests {
    @Test("a selection round-trips through the file it is stored in")
    func roundTripsThroughDisk() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AuspexPaths(homeDirectory: home)
        let store = CharacterSelectionStore(paths: paths)

        var selection = CharacterSelection()
        selection.setCharacterID("office-cat", for: .codex)
        selection.setCharacterID("claudeCode-default", for: .claudeCode)
        selection.setCharacterID(
            "office-cat", for: SessionKey(harness: .cursor, sessionID: "abc:123")
        )
        try store.save(selection)

        let reloaded = store.load()

        #expect(reloaded == selection)
        #expect(reloaded.characterID(for: .codex) == "office-cat")
        #expect(
            reloaded.characterID(for: SessionKey(harness: .cursor, sessionID: "abc:123"))
                == "office-cat"
        )
        #expect(paths.contains(store.url))
    }

    @Test("a missing or corrupt file is an empty selection, never an error")
    func toleratesAMissingOrCorruptFile() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AuspexPaths(homeDirectory: home)
        let store = CharacterSelectionStore(paths: paths)

        #expect(store.load().isEmpty)

        try paths.ensureBaseDirectory()
        try Data("nonsense".utf8).write(to: paths.characterSelectionURL)

        #expect(store.load().isEmpty)
    }

    @Test("clearing a harness's choice removes it from the file")
    func clearingRemovesTheEntry() {
        var selection = CharacterSelection()
        selection.setCharacterID("office-cat", for: .codex)
        selection.setCharacterID(nil, for: .codex)

        #expect(selection.characterID(for: .codex) == nil)
        #expect(selection.isEmpty)
    }

    @Test("pruning drops references to characters that no longer exist")
    func pruningDropsDanglingReferences() {
        var selection = CharacterSelection()
        selection.setCharacterID("gone", for: .codex)
        selection.setCharacterID("kept", for: .cursor)
        selection.setCharacterID("gone", for: SessionKey(harness: .codex, sessionID: "1"))

        selection.prune(keeping: ["kept"])

        #expect(selection.characterID(for: .codex) == nil)
        #expect(selection.characterID(for: .cursor) == "kept")
        #expect(selection.overridesBySession.isEmpty)
    }
}
