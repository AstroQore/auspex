import AgentSessionKit
import AgentSessionLive
import Foundation

/// The review-facing subset of a task's history.
///
/// An agent's result sentence, a recorded evidence reference, and an observed
/// checkout are three different claims. This model keeps the first on the
/// task, the second in these buckets, and the third in ``DeliverySnapshot`` so
/// a review surface never turns “tests passed” into a green observed state.
public struct TaskReviewDossier: Sendable, Equatable {
    public struct Entry: Identifiable, Sendable, Equatable {
        public let id: Int64
        public let message: String
        public let ref: String?
        public let timestamp: Date
        public let actor: SessionKey?

        public init(_ entry: AuspexTaskLogEntry) {
            id = entry.id
            message = entry.message?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ref = entry.ref?.trimmingCharacters(in: .whitespacesAndNewlines)
            timestamp = entry.timestamp
            actor = entry.actor
        }
    }

    public let evidence: [Entry]
    public let decisions: [Entry]
    public let risks: [Entry]

    public init(log: [AuspexTaskLogEntry]) {
        evidence = log.filter { $0.noteKind == .evidence }.map(Entry.init)
        decisions = log.filter { $0.noteKind == .decision }.map(Entry.init)
        risks = log.filter { $0.noteKind == .risk }.map(Entry.init)
    }
}

/// The local ordering policy for work waiting on a person.
///
/// Defer changes only this in-memory order. It does not write the task, clear
/// attention, mark anything complete, or survive a relaunch. Deferred work is
/// moved to the end rather than hidden, so the queue cannot quietly lose it.
public struct ReviewQueue: Sendable, Equatable {
    public enum Direction: Sendable { case previous, next }

    public private(set) var deferredIDs: Set<String>

    public init(deferredIDs: Set<String> = []) {
        self.deferredIDs = deferredIDs
    }

    public mutating func deferReview(id: String) { deferredIDs.insert(id) }
    public mutating func restoreReview(id: String) { deferredIDs.remove(id) }

    /// Drops ids that are no longer in Review. This is only housekeeping for
    /// the local queue and changes no task state.
    public mutating func reconcile(units: [TaskUnit]) {
        let reviewIDs = Set(units.lazy.filter(\.isInReview).map(\.id))
        deferredIDs.formIntersection(reviewIDs)
    }

    public func ordered(units: [TaskUnit]) -> [TaskUnit] {
        let reviews = units.filter(\.isInReview)
        return reviews.filter { !deferredIDs.contains($0.id) }
            + reviews.filter { deferredIDs.contains($0.id) }
    }

    public func first(units: [TaskUnit], excluding id: String? = nil) -> TaskUnit? {
        ordered(units: units).first { $0.id != id }
    }

    public func neighbor(
        of id: String,
        direction: Direction,
        units: [TaskUnit]
    ) -> TaskUnit? {
        let queue = ordered(units: units)
        guard let index = queue.firstIndex(where: { $0.id == id }) else { return nil }
        switch direction {
        case .previous:
            guard index > queue.startIndex else { return nil }
            return queue[queue.index(before: index)]
        case .next:
            let next = queue.index(after: index)
            guard next < queue.endIndex else { return nil }
            return queue[next]
        }
    }
}

/// A bounded, copyable packet for another person or agent to resume a task.
///
/// It contains no transcript and sends nothing. The user explicitly copies the
/// packet, and every claim inside is labelled by provenance.
public struct HandoffPacket: Sendable, Equatable {
    public struct ResumeHint: Sendable, Equatable {
        public let sessionLabel: String
        public let command: String?
        public let unavailableReason: String?

        public init(
            sessionLabel: String,
            command: String? = nil,
            unavailableReason: String? = nil
        ) {
            self.sessionLabel = sessionLabel
            self.command = command
            self.unavailableReason = unavailableReason
        }
    }

    public let text: String

    public init(
        unit: TaskUnit,
        log: [AuspexTaskLogEntry],
        delivery: DeliverySnapshot?,
        resumeHints: [ResumeHint] = []
    ) {
        let capsule = TaskCapsule(unit: unit)
        let dossier = TaskReviewDossier(log: log)
        var lines: [String] = [
            "# Handoff — \(Self.oneLine(unit.shortID)) · \(Self.oneLine(unit.title))",
            "",
            Self.field("Goal", capsule.goal),
            "Phase [derived]: \(capsule.phase.rawValue)"
        ]
        Self.append(&lines, name: "Current", line: capsule.current)
        Self.append(&lines, name: "Recent", line: capsule.recentOutcome)
        Self.append(&lines, name: "Next", line: capsule.nextAction)
        Self.append(&lines, name: "Risk", line: capsule.risk)

        lines += ["", "## Team"]
        for member in unit.members.prefix(32) {
            var facts = [
                member.key == unit.lead.key ? "lead" : "member",
                member.harness.displayName,
                member.shortID
            ]
            if let claim = unit.claim, claim.session == member.key {
                if let role = Self.clean(claim.role) { facts.append("role \(role)") }
                if let scope = Self.clean(claim.scope) { facts.append("scope \(scope)") }
            }
            lines.append(
                "- \(facts.map(Self.oneLine).joined(separator: " · ")) — "
                    + Self.oneLine(member.activity)
            )
        }

        lines += ["", "## Delivery"]
        lines.append(contentsOf: Self.deliveryLines(delivery))

        Self.appendEntries(dossier.evidence, heading: "Evidence [recorded]", to: &lines)
        Self.appendEntries(dossier.decisions, heading: "Decisions [recorded]", to: &lines)
        Self.appendEntries(dossier.risks, heading: "Risks [recorded]", to: &lines)

        if !resumeHints.isEmpty {
            lines += ["", "## Resume hints"]
            for hint in resumeHints.prefix(32) {
                if let command = Self.clean(hint.command) {
                    lines.append(
                        "- \(Self.oneLine(hint.sessionLabel)): `\(Self.inlineCode(command))`"
                    )
                } else if let reason = Self.clean(hint.unavailableReason) {
                    lines.append(
                        "- \(Self.oneLine(hint.sessionLabel)): unavailable — "
                            + Self.oneLine(reason)
                    )
                }
            }
        }

        // Clipboard payloads should stay useful even if an agent wrote a very
        // large note. Keep whole lines up to one deterministic ceiling.
        let joined = lines.joined(separator: "\n")
        text = String(joined.prefix(32 * 1_024))
    }

    private static func append(
        _ lines: inout [String],
        name: String,
        line: TaskCapsule.Line?
    ) {
        guard let line else { return }
        lines.append(field(name, line))
    }

    private static func field(_ name: String, _ line: TaskCapsule.Line) -> String {
        "\(name) [\(line.source.rawValue)]: \(oneLine(line.text))"
    }

    private static func appendEntries(
        _ entries: [TaskReviewDossier.Entry],
        heading: String,
        to lines: inout [String]
    ) {
        guard !entries.isEmpty else { return }
        lines += ["", "## \(heading)"]
        for entry in entries.suffix(20) {
            var line = "- \(oneLine(entry.message))"
            if let ref = clean(entry.ref) { line += " — `\(inlineCode(ref))`" }
            lines.append(line)
        }
    }

    private static func deliveryLines(_ snapshot: DeliverySnapshot?) -> [String] {
        guard let snapshot else {
            return ["- Local Git [observed]: unknown — no checkout was recorded for this task."]
        }
        let checked = ISO8601DateFormatter().string(from: snapshot.checkedAt)
        var lines = [
            "- Local Git [\(snapshot.provenance.rawValue), \(checked)]: \(snapshot.workingTree.rawValue)"
        ]
        if let path = snapshot.repositoryPath { lines.append("- Repository: `\(inlineCode(path))`") }
        if let branch = snapshot.branch { lines.append("- Branch: `\(inlineCode(branch))`") }
        if let count = snapshot.changedFileCount {
            let suffix = snapshot.changedFilesTruncated ? "+ (display capped)" : ""
            lines.append("- Changed files: \(count)\(suffix)")
        }
        for file in snapshot.changedFiles {
            lines.append("  - `\(inlineCode(file.status))` `\(inlineCode(file.path))`")
        }
        if let stat = clean(snapshot.diffstat) { lines.append("- Diffstat: \(oneLine(stat))") }
        if let commit = snapshot.lastCommit {
            lines.append("- Last commit: `\(inlineCode(commit.shortHash))` \(oneLine(commit.subject))")
        }
        if snapshot.ahead != nil || snapshot.behind != nil {
            lines.append("- Local upstream delta: ahead \(snapshot.ahead ?? 0), behind \(snapshot.behind ?? 0)")
        }
        if let diagnostic = clean(snapshot.diagnostic) {
            lines.append("- Observation note: \(oneLine(diagnostic))")
        }
        return lines
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func oneLine(_ value: String) -> String {
        let words = value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return String(words.prefix(1_000))
    }

    private static func inlineCode(_ value: String) -> String {
        oneLine(value).replacingOccurrences(of: "`", with: "'")
    }
}
