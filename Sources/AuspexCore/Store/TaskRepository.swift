import Foundation
import GRDB

/// Reads and writes the task ledger: milestones, tasks, claims, the log behind
/// them, and what agents said when they called for a person.
///
/// Every task carries a `project_key` in the board's own key space — see
/// ``TaskProject``. The repository never *resolves* one: it is handed the key
/// its caller worked out from the frame, because the frame is where a
/// session's project lives and a store that guessed would be a second answer
/// to a question that already has one.
///
/// A value over a `DatabaseWriter`, like ``SessionRepository``, so the MCP
/// server, the board model and a test can each make one without sharing
/// anything mutable. Every method does its own transaction; the ones that have
/// to be atomic against a concurrent claim say so in their own comments.
public struct TaskRepository: Sendable {
    public let dbWriter: any DatabaseWriter

    /// The two honest outcomes of an agent trying to take work.
    public enum ClaimOutcome: Sendable, Equatable {
        case claimed(AuspexTask)
        case pending(task: AuspexTask, request: TaskClaimRequest)
    }

    public init(dbWriter: any DatabaseWriter) {
        self.dbWriter = dbWriter
    }

    public init(store: AuspexStore) {
        self.dbWriter = store.dbWriter
    }
}

// MARK: - Labels

/// A task's labels, on their way in and out of the one column that holds them.
///
/// A JSON array of strings, and total in both directions: a column holding
/// something else — written by an older build, or by a person with `sqlite3`
/// open — decodes as no labels rather than sinking the query that read it.
public enum TaskLabels {
    /// How many labels one task may carry, and how long each may be.
    ///
    /// A cap rather than a validation error, for the reason every other
    /// agent-supplied string here is capped: an agent that gets an error back
    /// retries, and an agent that gets its list trimmed carries on.
    public static let limit = 12
    public static let lengthLimit = 40

    /// Trimmed, lowercased, deduplicated, capped — in the order given.
    public static func normalize(_ raw: [String]) -> [String] {
        var seen: Set<String> = []
        var kept: [String] = []
        for label in raw {
            let trimmed = label
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard !trimmed.isEmpty else { continue }
            let capped = String(trimmed.prefix(lengthLimit))
            guard seen.insert(capped).inserted else { continue }
            kept.append(capped)
            if kept.count == limit { break }
        }
        return kept
    }

    /// The column value, or `nil` when there is nothing to store.
    static func encode(_ labels: [String]) -> String? {
        let normalized = normalize(labels)
        guard !normalized.isEmpty else { return nil }
        guard let data = try? JSONEncoder().encode(normalized) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// What a column holds, read back.
    static func decode(_ raw: String?) -> [String] {
        guard let raw, !raw.isEmpty, let data = raw.data(using: .utf8) else { return [] }
        guard let decoded = try? JSONDecoder().decode([String].self, from: data) else { return [] }
        return normalize(decoded)
    }
}

// MARK: - Counts

/// How much work one project is carrying.
///
/// Two numbers rather than a list, because every reader of this is a badge: a
/// sidebar row, a Projects-page column, a lane header. "3 tasks open" is the
/// whole of what a person wants from a project they are not looking at.
public struct TaskProjectCounts: Hashable, Sendable {
    /// Every task in the project, finished ones included.
    public let total: Int
    /// The ones that are not in `done`.
    public let open: Int

    public init(total: Int, open: Int) {
        self.total = total
        self.open = open
    }

    /// What a badge says, or `nil` when the project carries nothing and the
    /// badge should not be drawn at all.
    public var openDescription: String? {
        guard open > 0 else { return nil }
        return open == 1 ? "1 task open" : "\(open) tasks open"
    }
}

// MARK: - Errors

/// What the ledger refuses to do, in words a tool result can quote.
public enum TaskLedgerError: Error, Sendable, Equatable, CustomStringConvertible {
    case notFound(String)
    case alreadyClaimed(String)
    case notClaimHolder(String?)
    case notTaskHolder(String?)
    case versionConflict(expected: Int64, actual: Int64)
    case dependencyNotFound(Int64)
    case selfDependency(Int64)
    case dependencyCycle([Int64])
    case claimRequestResolved(Int64)
    /// The board is read-only in this process — a demo replay.
    case readOnly

    public var description: String {
        switch self {
        case let .notFound(what): "No such \(what)."
        case let .alreadyClaimed(holder): "Already claimed by \(holder)."
        case let .notClaimHolder(holder?): "Only \(holder) can release this claim."
        case .notClaimHolder(nil): "This task has no claim for this session to release."
        case let .notTaskHolder(holder?): "Only the current holder, \(holder), can finish this task."
        case .notTaskHolder(nil): "Claim this task before finishing it."
        case let .versionConflict(expected, actual):
            "Task version changed: expected \(expected), current \(actual). Read tasks.get and retry deliberately."
        case let .dependencyNotFound(id):
            "Dependency task \(id) does not exist. The dependency graph was not changed."
        case let .selfDependency(id):
            "Task \(id) cannot depend on itself. The dependency graph was not changed."
        case let .dependencyCycle(path):
            "Dependency cycle \(path.map(String.init).joined(separator: " → ")); the graph was not changed."
        case let .claimRequestResolved(id):
            "Claim request \(id) has already been resolved."
        case .readOnly: "This Auspex is replaying a demo board and will not write to it."
        }
    }
}

// MARK: - Slugs

/// The handle a plan travels under.
public enum TaskSlug {
    /// Lowercases, keeps letters, digits, and dashes, and collapses everything
    /// else into single dashes.
    ///
    /// Deliberately not a general slugifier: it is applied to *agent input*, so
    /// its job is to produce something short, safe to print in a brief, and
    /// impossible to confuse with a path or a shell word. Non-ASCII letters
    /// survive — a Chinese plan title should stay legible rather than become
    /// a row of dashes.
    public static func make(_ raw: String, limit: Int = 64) -> String {
        var out = ""
        var lastWasDash = false
        for character in raw.lowercased() {
            if character.isLetter || character.isNumber {
                out.append(character)
                lastWasDash = false
            } else if !lastWasDash, !out.isEmpty {
                out.append("-")
                lastWasDash = true
            }
            if out.count >= limit { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out.isEmpty ? "plan" : out
    }
}
