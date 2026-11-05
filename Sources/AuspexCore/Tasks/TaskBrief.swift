import Foundation

/// What a task is for, in the shape a worker can act on and a reviewer can
/// check — and the one layout it is stored in.
///
/// ## Why structure, and why it is stored as text
///
/// A body is free text, and what agents put in free text is a paragraph of
/// intentions with the acceptance criteria somewhere in the middle, phrased as
/// things not to do. The fields here are what a brief actually needs: one
/// sentence of objective, the outcomes that mean it is finished, what to hand
/// back, and where the edges are.
///
/// They are composed into the existing `body` column in a fixed layout rather
/// than given columns of their own. Every reader of a task — `tasks.get`, the
/// detail page, a worker's brief — already shows the body, so a structured
/// task is legible everywhere on the day it ships, and a client that only
/// knows `body` keeps working unchanged.
public struct TaskBrief: Sendable, Equatable {
    public var objective: String?
    /// Checkable outcomes: a test passes, a file exists, a number is reached.
    public var acceptance: [String]
    public var deliverable: String?
    public var scope: String?
    public var outOfScope: String?
    /// Whatever the caller passed as `body`, kept after the structured part.
    public var notes: String?

    public init(
        objective: String? = nil,
        acceptance: [String] = [],
        deliverable: String? = nil,
        scope: String? = nil,
        outOfScope: String? = nil,
        notes: String? = nil
    ) {
        self.objective = Self.clean(objective)
        self.acceptance = acceptance.compactMap(Self.clean)
        self.deliverable = Self.clean(deliverable)
        self.scope = Self.clean(scope)
        self.outOfScope = Self.clean(outOfScope)
        self.notes = Self.clean(notes)
    }

    /// Whether any of the structured fields was given.
    public var isStructured: Bool {
        objective != nil || !acceptance.isEmpty || deliverable != nil || scope != nil
            || outOfScope != nil
    }

    /// The body to store: the structured fields in a fixed order, then the
    /// notes. Just the notes when nothing structured was given, and `nil`
    /// when there is nothing at all.
    public var composed: String? {
        guard isStructured else { return notes }
        var sections: [String] = []
        if let objective { sections.append("Objective: \(objective)") }
        if !acceptance.isEmpty {
            sections.append((["Acceptance:"] + acceptance.map { "- \($0)" }).joined(separator: "\n"))
        }
        let edges = [
            deliverable.map { "Deliverable: \($0)" },
            scope.map { "Scope: \($0)" },
            outOfScope.map { "Out of scope: \($0)" }
        ].compactMap { $0 }
        if !edges.isEmpty { sections.append(edges.joined(separator: "\n")) }
        if let notes { sections.append("Notes:\n\(notes)") }
        return sections.joined(separator: "\n\n")
    }

    private static func clean(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}

/// The form two task titles are compared in when deciding whether a new one
/// is a duplicate.
public enum TaskTitle {
    /// Lowercased, with every space, punctuation mark and symbol removed:
    /// "Fix the login redirect." and "fix  the Login-Redirect" are one title.
    /// Letters and digits of every script are kept, so two Chinese titles
    /// that differ by a character stay different.
    public static func normalized(_ title: String) -> String {
        String(String.UnicodeScalarView(
            title.lowercased().unicodeScalars.filter {
                CharacterSet.letters.contains($0) || CharacterSet.decimalDigits.contains($0)
            }
        ))
    }
}
