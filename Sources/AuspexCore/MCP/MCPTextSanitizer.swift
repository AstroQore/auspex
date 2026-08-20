import AgentSessionKit
import Foundation

/// Everything an agent types into a tool argument passes through here first.
///
/// Tool input is the one place in Auspex where a *model* writes directly into
/// the database and onto the screen. It is not hostile by assumption, but it is
/// generated text: it can be a megabyte long, it can carry ANSI escapes that
/// rearrange a terminal, it can carry bidirectional overrides that make a
/// notification read backwards, and it can carry a NUL that truncates a C
/// string somewhere downstream.
///
/// So the rule is the same as for argv (`AGENTS.md` § 6): sanitize at the
/// boundary, once, before the value reaches a log line, the database, or the
/// UI. Nothing here executes, interprets, or expands anything — the output is
/// always a plain, bounded, single-purpose string.
public enum MCPTextSanitizer {
    /// The cap the brief sets for a message, a focus line, or a scope.
    ///
    /// Five hundred characters is about six lines on a card. Anything longer
    /// is a transcript, and a transcript belongs in the session it came from,
    /// not on a notification.
    public static let defaultLimit = 500

    /// A shorter cap for the values that are *labels* rather than sentences —
    /// a role, a slug, a progress marker. Long enough for "implementation
    /// reviewer", short enough that a column heading cannot be made to push
    /// the board sideways.
    public static let labelLimit = 80

    /// Strips what must never survive, collapses what must not repeat, and
    /// truncates what is left.
    ///
    /// - Control characters go, including the ones that would let a message
    ///   rewrite a terminal or reverse its own reading order. A newline and a
    ///   tab become a space rather than disappearing, because they were
    ///   separating words.
    /// - Runs of whitespace collapse to one space, so a message padded to look
    ///   like a heading is drawn as the sentence it is.
    /// - The result is truncated on a character boundary and marked with an
    ///   ellipsis, so a reader can tell there was more.
    ///
    /// - Returns: `nil` when nothing legible is left, which the caller treats
    ///   as "the argument was not given".
    public static func clean(_ raw: String?, limit: Int = defaultLimit) -> String? {
        guard let raw else { return nil }
        var out = ""
        out.reserveCapacity(min(raw.count, limit + 1))
        var lastWasSpace = false
        for scalar in raw.unicodeScalars {
            let character = Character(scalar)
            if scalar.properties.isBidiControl || isControl(scalar) || isFormat(scalar) {
                // A separator becomes a space; everything else vanishes.
                guard character.isWhitespace else { continue }
                if !lastWasSpace, !out.isEmpty { out.append(" ") }
                lastWasSpace = true
                continue
            }
            if character.isWhitespace {
                if !lastWasSpace, !out.isEmpty { out.append(" ") }
                lastWasSpace = true
                continue
            }
            out.append(character)
            lastWasSpace = false
            // One past the limit is enough to know it needs an ellipsis.
            if out.count > limit { break }
        }
        while out.hasSuffix(" ") { out.removeLast() }
        guard !out.isEmpty else { return nil }
        guard out.count > limit else { return out }
        return String(out.prefix(limit - 1)) + "…"
    }

    /// The same, for a value the caller insists on having.
    public static func require(
        _ raw: String,
        limit: Int = defaultLimit,
        field: String,
        tool: String
    ) throws -> String {
        guard let cleaned = clean(raw, limit: limit) else {
            throw MCPRPCError.invalidParams("\(tool): '\(field)' must not be empty.")
        }
        return cleaned
    }

    /// C0, C1, and the private-use control range, without asking Foundation for
    /// a `CharacterSet` on every scalar.
    private static func isControl(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value < 0x20 || (scalar.value >= 0x7F && scalar.value <= 0x9F)
    }

    /// Zero-width joiners, invisible separators, and the interlinear
    /// annotation marks — the characters that are legal in a name and are only
    /// ever used in a tool argument to make two different strings look alike.
    private static func isFormat(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x200B...0x200F, 0x2028...0x202F, 0x2060...0x206F, 0xFEFF, 0xFFF9...0xFFFB:
            true
        default:
            false
        }
    }
}
