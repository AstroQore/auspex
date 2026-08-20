import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import Observation
import SpriteKit

/// The name of one animation on disk.
///
/// Deliberately not ``SessionState``. A state carries a payload the art does
/// not care about — which tool, which file — and there are more states than
/// there are things worth drawing: `toolCalling` and `writingFile` are both
/// "typing", they just differ in tempo and screen colour. So the character
/// package has its own small vocabulary, and one place maps states onto it.
///
/// The names are exactly ``CharacterPose``'s, because they are the same
/// vocabulary seen from the two sides of the app: the scene asks in
/// ``ScenePose``, the loader answers from a folder of files named after
/// ``CharacterPose``.
enum ScenePose: String, CaseIterable, Sendable {
    /// Nothing outstanding. The slumped, still pose.
    case idle
    /// Reasoning. A slow head bob and a breathing screen.
    case thinking
    /// A tool is open. Hands moving.
    case typing
    /// The working tree is being changed.
    case writing
    /// Handing work to a subagent.
    case delegating
    /// Blocked on a person. One hand up.
    case blocked
    /// Working, but silent for longer than it should be.
    case stale
    /// Over. The chair is all that is left.
    case ended

    /// The pose a session in this state is drawn in.
    static func pose(for state: SessionState, isStale: Bool) -> ScenePose {
        // Staleness is a modifier on the board and a *pose* here, but only for
        // a session that claims to be working. A stale idle session is just an
        // idle session, and drawing it asleep would say something the board
        // does not.
        if isStale, state.isActive { return .stale }
        switch state {
        case .idle: return .idle
        case .thinking: return .thinking
        case .toolCalling: return .typing
        case .writingFile: return .writing
        case .delegating: return .delegating
        case .waitingPermission: return .blocked
        case .ended: return .ended
        }
    }

    /// The same pose, as the loader spells it.
    var characterPose: CharacterPose {
        CharacterPose(rawValue: rawValue) ?? .idle
    }
}

/// Where the office gets its people.
///
/// ## The contract
///
/// A character is a *package*: a folder holding `character.json` and one
/// horizontal frame strip per pose. `docs/CHARACTERS.md` is the full
/// specification and the thing to hand to whoever is drawing.
///
/// Two roots are read, and a package in the second replaces one with the same
/// id in the first:
///
/// 1. `Characters/` inside the app bundle — the eight people who ship with
///    Auspex, one per harness.
/// 2. `~/.auspex/characters/` — the person's own. Watched, so a package
///    dropped in appears without a relaunch, and a strip redrawn in place
///    updates the office while it is on screen.
///
/// ## Why a fallback rather than a requirement
///
/// There will always be a harness nobody has drawn yet, and a board that
/// silently dropped its sessions because their PNG was missing would be worse
/// than one drawn with rectangles. So every lookup that fails resolves to
/// ``PlaceholderArt``'s procedural rig — per *pose*, not per character, which
/// is what lets art land one pose at a time. A package with only `blocked.png`
/// in it makes exactly the sessions that need a person look like people.
///
/// ## Two scales, one apparent size
///
/// A 48-pixel cell is a *more detailed* character, not a bigger one. Both cell
/// sizes are drawn 64 points tall, so an office mixing them has one population
/// rather than two — 32-pixel art at two points per pixel, 48-pixel art at one
/// and a third.
@MainActor
@Observable
final class SpriteLibrary {
    static let shared = SpriteLibrary()

    /// One loaded animation.
    struct Strip {
        /// The frames, left to right.
        let frames: [SKTexture]
        /// How fast to play them.
        let fps: Double
        /// Scene points per art pixel, so a cell of any legal size lands the
        /// same height on screen.
        let pointsPerPixel: CGFloat

        /// How long one frame is on screen.
        var timePerFrame: TimeInterval { fps > 0 ? 1 / fps : 0.12 }
    }

    /// The apparent height of a character, in scene points. A 32-pixel cell at
    /// ``PlaceholderArt/pixelScale``, which is what every desk was laid out
    /// against.
    static let cellPoints = CGFloat(CharacterManifest.defaultCell) * PlaceholderArt.pixelScale

    /// Every package Auspex can draw right now.
    private(set) var catalog = CharacterCatalog()

    /// Who wears what.
    private(set) var selection = CharacterSelection()

    /// Bumped on every reload. Views that cache anything derived from a
    /// package can observe it instead of comparing catalogs.
    private(set) var generation = 0

    /// The last error from saving a choice, for the Settings pane to show.
    private(set) var selectionErrorDescription: String?

    private let paths: AuspexPaths
    private let library: CharacterLibrary
    private let selectionStore: CharacterSelectionStore
    private var watcher: CharacterFolderWatcher?

    /// Loaded strips, keyed by `"<package id>/<pose>"`. Misses are cached as
    /// hard as hits: a lookup happens when a sprite is created and when its
    /// pose changes, which on a busy board is often enough that hitting the
    /// filesystem each time would be a real cost for an answer that does not
    /// change between reloads.
    private var cache: [String: Strip?] = [:]

    /// Every sprite currently on screen, weakly. A reload has to repaint the
    /// office, and the desks only re-apply a pose when the *session* changes —
    /// so the sprites are told directly rather than through a board frame that
    /// may not arrive for minutes.
    private let liveSprites = NSHashTable<AgentSprite>.weakObjects()

    init(paths: AuspexPaths = .default) {
        self.paths = paths
        self.library = CharacterLibrary(
            builtInDirectory: Self.bundledCharactersDirectory,
            userDirectory: paths.charactersDirectory
        )
        self.selectionStore = CharacterSelectionStore(paths: paths)
        reload()
    }

    /// `~/.auspex/characters`.
    var charactersDirectory: URL { paths.charactersDirectory }

    /// Starts watching the user's folder. Idempotent; the scene calls it.
    func startWatching() {
        guard watcher == nil else { return }
        let watcher = CharacterFolderWatcher(url: paths.charactersDirectory) {
            Task { @MainActor in SpriteLibrary.shared.reload() }
        }
        self.watcher = watcher
        watcher.start()
    }

    /// Re-reads both roots, throws away every texture, and repaints whatever
    /// is on screen.
    func reload() {
        catalog = library.scan()
        selection = selectionStore.load()
        cache.removeAll(keepingCapacity: true)
        generation &+= 1
        for sprite in liveSprites.allObjects { sprite.refreshArt() }
    }

    /// Creates `~/.auspex/characters/` if it is not there and returns it, so
    /// the Settings pane's button has somewhere to open.
    @discardableResult
    func ensureCharactersDirectory() -> URL? {
        try? paths.ensureCharactersDirectory()
    }

    // MARK: Choosing

    /// Sets what every session of `harness` is drawn as: a package, Auspex's
    /// own built-in figures, or automatic — whichever package claims the
    /// harness, and the built-in figures while none does.
    func setChoice(_ choice: CharacterChoice, for harness: Harness) {
        var next = selection
        next.setChoice(choice, for: harness)
        apply(next)
    }

    /// Sets what one session is drawn as, overriding its harness.
    func setChoice(_ choice: CharacterChoice, for key: SessionKey) {
        var next = selection
        next.setChoice(choice, for: key)
        apply(next)
    }

    private func apply(_ next: CharacterSelection) {
        selection = next
        do {
            try selectionStore.save(next)
            selectionErrorDescription = nil
        } catch {
            // The choice still takes effect for this launch. Saying so is
            // better than pretending it was written.
            selectionErrorDescription = String(describing: error)
        }
        cache.removeAll(keepingCapacity: true)
        generation &+= 1
        for sprite in liveSprites.allObjects { sprite.refreshArt() }
    }

    // MARK: Lookups

    /// The package one session's agent is drawn as, or `nil` when it wears
    /// the procedural rig — because that was chosen, or because nobody has
    /// drawn its harness.
    func package(for key: SessionKey) -> CharacterPackage? {
        catalog.package(for: key, selection: selection)
    }

    /// The strip for one session and pose, or `nil` when nobody has drawn it
    /// and the caller should fall back to the procedural rig.
    func strip(for key: SessionKey, pose: ScenePose) -> Strip? {
        guard let package = package(for: key) else { return nil }
        return strip(in: package, pose: pose.characterPose)
    }

    /// The walk one session plays while it crosses the map.
    ///
    /// A separate lookup from ``strip(for:pose:)`` because walking is not a
    /// ``ScenePose``: no state puts a session in it, and adding one would mean
    /// every switch over what a session is doing had to answer for a case the
    /// board can never produce. Left is not asked for at all — it is
    /// `walkRight`, mirrored by the caller.
    func walkStrip(for key: SessionKey, facing direction: SceneWalkDirection) -> Strip? {
        guard let package = package(for: key),
              let pose = CharacterPose(rawValue: direction.poseName)
        else { return nil }
        return strip(in: package, pose: pose)
    }

    /// The strip for one pose of a named package.
    func strip(in package: CharacterPackage, pose: CharacterPose) -> Strip? {
        let key = "\(package.id)/\(pose.rawValue)"
        if let cached = cache[key] { return cached }
        let loaded = package.file(for: pose).flatMap(Self.load(_:))
        cache[key] = loaded
        return loaded
    }

    // MARK: Live sprites

    func register(_ sprite: AgentSprite) {
        liveSprites.add(sprite)
    }

    // MARK: Loading

    /// Slices a strip into frames.
    ///
    /// The cell edge comes from the package rather than from the image's
    /// height, because a package that got its `cell` wrong should be reported
    /// by the loader and drawn as best it can be, not silently reinterpreted
    /// into a shape nobody declared.
    private static func load(_ file: CharacterPackage.PoseFile) -> Strip? {
        guard let image = NSImage(contentsOf: file.url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              file.cell > 0,
              file.frames > 0,
              cgImage.width >= file.cell
        else { return nil }

        let sheet = SKTexture(cgImage: cgImage)
        sheet.filteringMode = .nearest

        let columns = min(file.frames, cgImage.width / file.cell)
        var frames: [SKTexture] = []
        frames.reserveCapacity(columns)
        for column in 0..<columns {
            // SKTexture's sub-rectangle is in normalised coordinates with the
            // origin at the bottom left, which for a single-row strip means
            // only `x` varies.
            let rect = CGRect(
                x: CGFloat(column * file.cell) / CGFloat(cgImage.width),
                y: 0,
                width: CGFloat(file.cell) / CGFloat(cgImage.width),
                height: 1
            )
            let frame = SKTexture(rect: rect, in: sheet)
            frame.filteringMode = .nearest
            frames.append(frame)
        }
        guard !frames.isEmpty else { return nil }

        return Strip(
            frames: frames,
            fps: file.fps,
            pointsPerPixel: cellPoints / CGFloat(file.cell)
        )
    }

    /// `Auspex.app/Contents/Resources/Characters`, when this build is a bundle
    /// that has any. `nil` for `swift run`, where there is no `Contents`.
    private static var bundledCharactersDirectory: URL? {
        guard let resources = Bundle.main.resourceURL else { return nil }
        let directory = resources.appendingPathComponent("Characters", isDirectory: true)
        return FileManager.default.fileExists(atPath: directory.path) ? directory : nil
    }
}
