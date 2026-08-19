import Foundation
import Testing

@testable import AuspexCore

/// Counts callbacks from a watcher, across the queue it fires them on.
private actor ChangeCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }

    /// Waits for the count to rise above `mark`, or gives up.
    func waitForChange(above mark: Int, seconds: Double = 8) async -> Int {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if count > mark { return count }
            try? await Task.sleep(for: .milliseconds(40))
        }
        return count
    }
}

@Suite("Character folder watcher", .serialized)
struct CharacterFolderWatcherTests {
    /// FSEvents arms asynchronously and coalesces on its own latency window.
    /// Everything here is generous about *when* rather than about *whether*.
    private static let armingDelay = Duration.milliseconds(400)

    @Test("a package appearing, changing, and going away each report once")
    func reportsTheLifeOfAPackage() async throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AuspexPaths(homeDirectory: home)
        let folder = try paths.ensureCharactersDirectory()

        let counter = ChangeCounter()
        let watcher = CharacterFolderWatcher(url: folder, latency: 0.05, debounce: 0.1) {
            Task { await counter.increment() }
        }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: Self.armingDelay)

        // Appearing.
        try CharacterFixtures.writePackage(in: folder, id: "watched", poses: ["idle": (2, 2)])
        let afterCreate = await counter.waitForChange(above: 0)
        #expect(afterCreate > 0, "creating a package did not report a change")

        let library = CharacterLibrary(builtInDirectory: nil, userDirectory: folder)
        #expect(library.scan().package(id: "watched") != nil)

        // Changing a strip *inside* the package, which is the case a vnode
        // source on the root folder would miss entirely.
        try await Task.sleep(for: Self.armingDelay)
        let before = await counter.count
        try CharacterFixtures.writeStrip(
            to: folder.appendingPathComponent("watched/idle.png"),
            cell: 32,
            frames: 4
        )
        let afterEdit = await counter.waitForChange(above: before)
        #expect(afterEdit > before, "redrawing a strip in place did not report a change")
        #expect(library.scan().package(id: "watched")?.file(for: .idle)?.frames == 4)

        // Going away.
        try await Task.sleep(for: Self.armingDelay)
        let beforeRemoval = await counter.count
        try FileManager.default.removeItem(at: folder.appendingPathComponent("watched"))
        let afterRemoval = await counter.waitForChange(above: beforeRemoval)
        #expect(afterRemoval > beforeRemoval, "deleting a package did not report a change")
        #expect(library.scan().packages.isEmpty)
    }

    @Test("a folder that does not exist yet is picked up when it appears")
    func armsItselfWhenTheFolderAppears() async throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AuspexPaths(homeDirectory: home)

        #expect(!FileManager.default.fileExists(atPath: paths.charactersDirectory.path))

        let counter = ChangeCounter()
        let watcher = CharacterFolderWatcher(
            url: paths.charactersDirectory,
            latency: 0.05,
            debounce: 0.1
        ) {
            Task { await counter.increment() }
        }
        watcher.start()
        defer { watcher.stop() }
        try await Task.sleep(for: Self.armingDelay)

        // Auspex does not create this folder on its own; a person does, by
        // pressing "Open characters folder" or by hand. The watcher has to
        // notice without being restarted.
        try paths.ensureCharactersDirectory()
        try CharacterFixtures.writePackage(
            in: paths.charactersDirectory, id: "late", poses: ["idle": (2, 2)]
        )

        // The retry interval is three seconds, so this is the one wait that
        // genuinely needs to be long.
        let changes = await counter.waitForChange(above: 0, seconds: 12)
        #expect(changes > 0, "a folder created after start() never reported a change")
    }

    @Test("stop() means no more callbacks")
    func stopEndsTheCallbacks() async throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AuspexPaths(homeDirectory: home)
        let folder = try paths.ensureCharactersDirectory()

        let counter = ChangeCounter()
        let watcher = CharacterFolderWatcher(url: folder, latency: 0.05, debounce: 0.1) {
            Task { await counter.increment() }
        }
        watcher.start()
        try await Task.sleep(for: Self.armingDelay)
        try CharacterFixtures.writePackage(in: folder, id: "before", poses: ["idle": (2, 2)])
        _ = await counter.waitForChange(above: 0)

        watcher.stop()
        try await Task.sleep(for: Self.armingDelay)
        let settled = await counter.count
        try CharacterFixtures.writePackage(in: folder, id: "after", poses: ["idle": (2, 2)])
        try await Task.sleep(for: .milliseconds(900))

        #expect(await counter.count == settled)
    }

    @Test("the characters folder is inside the tree Auspex owns")
    func charactersFolderIsContained() throws {
        let home = try CharacterFixtures.temporaryHome()
        defer { try? FileManager.default.removeItem(at: home) }
        let paths = AuspexPaths(homeDirectory: home)

        #expect(paths.contains(paths.charactersDirectory))
        #expect(paths.contains(paths.characterSelectionURL))
        #expect(paths.charactersDirectory.lastPathComponent == "characters")

        let created = try paths.ensureCharactersDirectory()
        let mode = try FileManager.default
            .attributesOfItem(atPath: created.path)[.posixPermissions] as? NSNumber
        #expect(mode?.int16Value == Int16(AuspexPaths.directoryPermissions))
    }
}
