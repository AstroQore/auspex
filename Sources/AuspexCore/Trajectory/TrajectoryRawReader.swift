import Foundation

/// What came back when a step's original record was asked for.
///
/// Two cases, and the failure carries a sentence rather than an error code,
/// because the pane that shows it has nothing else to say and "the transcript
/// was rotated an hour ago" is genuinely the answer.
public enum TrajectoryRawOutcome: Hashable, Sendable {
    /// The record, pretty-printed when it parsed as JSON and verbatim when it
    /// did not.
    case record(String)
    /// Why there is nothing to show.
    case unavailable(String)

    public var text: String? {
        if case .record(let text) = self { return text }
        return nil
    }

    public var message: String? {
        if case .unavailable(let message) = self { return message }
        return nil
    }
}

/// Reads the original transcript line behind a step, on demand.
///
/// ## Read-only in the strong sense
///
/// This opens a *harness's own* file, which is the one part of the trajectory
/// that touches somebody else's directory. It opens for reading, seeks, reads
/// one bounded window, and closes. It never creates the file, never writes to
/// it, never repairs a path it did not like, and never follows the locator
/// into a store it does not know how to read — `AGENTS.md` § 6 applies to a
/// transcript line exactly as it applies to a transcript.
///
/// ## Why it is lazy
///
/// A trajectory can hold five thousand steps, each pointing at a line that may
/// be tens of kilobytes. Reading them with the trajectory would be reading a
/// whole transcript back off disk to draw a list of one-line summaries. The
/// Raw tab is opened for one step at a time, so the read happens for one step
/// at a time.
///
/// ## Misses are normal
///
/// A source can be rotated, compacted, or deleted between the observation and
/// the click; some harnesses record a SQLite row id rather than a byte offset,
/// and re-opening another tool's live database to satisfy a curiosity is not a
/// trade this app makes. Every one of those ends in ``TrajectoryRawOutcome/unavailable(_:)``
/// with the reason, which is a better answer than an empty pane.
public enum TrajectoryRawReader: Sendable {
    /// The most of one record this will read. Larger than any transcript line
    /// worth looking at, small enough that a corrupt offset cannot pull a
    /// gigabyte into a text view.
    public static let byteLimit = 256 * 1024

    /// File extensions whose records are one line at a byte offset. Anything
    /// else keeps its locator and gets an explanation.
    private static let lineOriented: Set<String> = ["jsonl", "ndjson"]

    /// Reads the record `ref` points at. Blocking; call it off the main actor.
    public static func read(_ ref: TrajectoryRawRef) -> TrajectoryRawOutcome {
        guard let offset = ref.offset, offset >= 0 else {
            return .unavailable("The source recorded no locator for this event.")
        }
        let url = URL(fileURLWithPath: ref.path)
        let extensionName = url.pathExtension.lowercased()
        guard lineOriented.contains(extensionName) else {
            return .unavailable(
                "This harness stores its records in \(url.lastPathComponent), which is not a "
                    + "line-oriented transcript. Auspex kept the locator (\(offset)) but does not "
                    + "re-open another harness's store to read a single row."
            )
        }
        guard FileManager.default.isReadableFile(atPath: ref.path) else {
            return .unavailable("The source file is no longer readable: \(ref.path)")
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            return .unavailable("The source file could not be opened: \(ref.path)")
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: UInt64(offset))
            guard let window = try handle.read(upToCount: byteLimit), !window.isEmpty else {
                return .unavailable(
                    "The record is past the end of the file. The transcript has been rewritten or "
                        + "rotated since Auspex read it."
                )
            }
            return decode(line(in: window))
        } catch {
            return .unavailable("The source file could not be read: \(ref.path)")
        }
    }

    /// The bytes up to the first newline — one record, however long the window
    /// turned out to be.
    private static func line(in window: Data) -> Data {
        guard let newline = window.firstIndex(of: 0x0A) else { return window }
        return window[window.startIndex..<newline]
    }

    /// The record as text: pretty-printed when it is JSON, verbatim when it is
    /// not.
    ///
    /// Verbatim rather than an error, because a line this cannot parse is
    /// still the line the event came from, and showing it is what the tab is
    /// for.
    private static func decode(_ data: Data) -> TrajectoryRawOutcome {
        guard !data.isEmpty else {
            return .unavailable("The record at that offset is empty.")
        }
        if let object = try? JSONSerialization.jsonObject(with: data),
           let pretty = try? JSONSerialization.data(
               withJSONObject: object,
               options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
           ) {
            return .record(String(decoding: pretty, as: UTF8.self))
        }
        return .record(String(decoding: data, as: UTF8.self))
    }
}
