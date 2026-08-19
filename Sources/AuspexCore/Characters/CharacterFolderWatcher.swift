import CoreServices
import Foundation

/// Watches `~/.auspex/characters/` and says when it changed.
///
/// ## Why FSEvents and not a `DispatchSource` on the directory
///
/// A character package is a *folder*: `character.json` and eight strips inside
/// `~/.auspex/characters/<id>/`. A vnode source on the root only fires when the
/// root's own entries change, so redrawing `blocked.png` in place — which is
/// what an artist does forty times in an afternoon — would never be noticed.
/// FSEvents watches the subtree, which is the thing that actually changes.
///
/// ## Debounced twice, on purpose
///
/// Saving a PNG from an image editor is several filesystem operations, and a
/// script that writes eight strips is dozens. FSEvents' own latency window
/// coalesces the burst, and a second debounce on this side coalesces what
/// survives it — because the work on the other end of this callback is a
/// directory scan plus throwing away every texture the scene has cached, and
/// doing that eight times in one second would make the office stutter for the
/// exact person who is trying to look at their new art.
///
/// ## A folder that is not there yet
///
/// Auspex never creates this directory on its own — a person who has not
/// customised anything should not find empty folders in their home. So the
/// watcher tolerates the folder not existing: it checks back every few seconds
/// and arms itself the moment the folder appears, which is what makes "click
/// Open characters folder, drop a package in" work without a relaunch.
public final class CharacterFolderWatcher: @unchecked Sendable {
    /// The folder being watched.
    public let url: URL

    private let latency: CFTimeInterval
    private let debounce: DispatchTimeInterval
    private let handler: @Sendable () -> Void
    private let queue: DispatchQueue

    private var stream: FSEventStreamRef?
    private var pending: DispatchWorkItem?
    private var appearanceTimer: DispatchSourceTimer?
    private var isRunning = false

    /// How often to look for a folder that does not exist yet.
    private static let appearanceInterval: DispatchTimeInterval = .seconds(3)

    public init(
        url: URL,
        latency: TimeInterval = 0.2,
        debounce: TimeInterval = 0.35,
        onChange: @escaping @Sendable () -> Void
    ) {
        self.url = url
        self.latency = latency
        self.debounce = .milliseconds(Int(debounce * 1000))
        self.handler = onChange
        self.queue = DispatchQueue(
            label: "com.astroqore.auspex.characters.watcher",
            qos: .utility
        )
    }

    deinit {
        // Not `stop()`: that hops onto `queue`, and a `sync` from `deinit` on
        // an object the queue could still reference is how a deadlock is
        // written. Tear the stream down directly — by the time `deinit` runs,
        // nothing else holds a reference to schedule work through.
        pending?.cancel()
        appearanceTimer?.cancel()
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }

    /// Starts watching. Idempotent.
    public func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            arm()
        }
    }

    /// Stops watching and drops any change that had not fired yet.
    public func stop() {
        queue.async { [self] in
            isRunning = false
            pending?.cancel()
            pending = nil
            appearanceTimer?.cancel()
            appearanceTimer = nil
            guard let stream else { return }
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
            self.stream = nil
        }
    }

    // MARK: Arming

    /// Creates the stream, or schedules another look when the folder is not
    /// there yet. Always on ``queue``.
    private func arm() {
        guard isRunning, stream == nil else { return }
        guard FileManager.default.fileExists(atPath: url.path) else {
            waitForAppearance()
            return
        }
        appearanceTimer?.cancel()
        appearanceTimer = nil

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<CharacterFolderWatcher>.fromOpaque(info)
                .takeUnretainedValue()
                .changed()
        }
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagWatchRoot
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            [url.path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            flags
        ) else {
            waitForAppearance()
            return
        }

        FSEventStreamSetDispatchQueue(created, queue)
        guard FSEventStreamStart(created) else {
            FSEventStreamInvalidate(created)
            FSEventStreamRelease(created)
            waitForAppearance()
            return
        }
        stream = created
    }

    private func waitForAppearance() {
        guard isRunning, appearanceTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.appearanceInterval, repeating: Self.appearanceInterval)
        timer.setEventHandler { [weak self] in
            guard let self, stream == nil else { return }
            arm()
            // The folder appeared between two ticks, so the caller has not been
            // told about whatever is already inside it.
            if stream != nil { changed() }
        }
        appearanceTimer = timer
        timer.resume()
    }

    /// Coalesces a burst of filesystem events into one callback.
    private func changed() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, isRunning else { return }
            pending = nil
            handler()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + debounce, execute: work)
    }
}
