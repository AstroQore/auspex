import Foundation

/// Text-level editors for the two config formats harnesses use.
///
/// ## Why not a parser and a re-serialiser
///
/// The obvious implementation is: decode the file, add a key, encode it again.
/// It is also the one that does the most damage. `~/.claude.json` is hundreds
/// of kilobytes of a running tool's own state; re-serialising it reorders every
/// key, reformats every number, and hands the user back a file that differs
/// from theirs on every line — which is indistinguishable, in a diff or a
/// backup, from something having gone wrong. And a TOML round trip through any
/// library loses comments outright.
///
/// So both editors work on the text and **only ever add or remove the region
/// Auspex wrote**. Every byte somebody else authored comes out the far side
/// unchanged, which is what makes "uninstall restores exactly what was there"
/// a fact rather than a hope.
enum ConfigTextEditors {}

// MARK: - JSON

/// A scanner that finds where a member of a JSON object lives in the text.
///
/// Enough JSON to locate a key and the exact span of its value: strings with
/// escapes, and nesting depth through objects and arrays. It does not validate
/// — the caller parses the result with `JSONSerialization` before and after
/// every edit, which is the check that actually matters.
enum JSONTextEditor {
    /// One `"key": value` pair and where it sits.
    struct Member {
        let name: String
        /// The whole pair, from the opening quote of the key to the end of the
        /// value — not including any comma or surrounding whitespace.
        let range: Range<String.Index>
    }

    /// The offset of the top-level object's `{`, or `nil` when the document is
    /// not an object.
    static func topLevelObjectStart(in text: String) -> String.Index? {
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            if character.isWhitespace { index = text.index(after: index); continue }
            return character == "{" ? index : nil
        }
        return nil
    }

    /// The members of the object whose `{` is at `start`.
    ///
    /// `nil` when the object does not close — a truncated file, which is a
    /// thing to refuse rather than to patch.
    static func members(in text: String, objectAt start: String.Index) -> [Member]? {
        guard start < text.endIndex, text[start] == "{" else { return nil }
        var members: [Member] = []
        var index = text.index(after: start)

        while true {
            index = skippingWhitespace(in: text, from: index)
            guard index < text.endIndex else { return nil }
            if text[index] == "}" { return members }
            if text[index] == "," {
                index = text.index(after: index)
                continue
            }
            guard text[index] == "\"" else { return nil }
            let keyStart = index
            guard let keyEnd = endOfString(in: text, from: index) else { return nil }
            let name = unescaped(String(text[text.index(after: keyStart)..<text.index(before: keyEnd)]))

            var cursor = skippingWhitespace(in: text, from: keyEnd)
            guard cursor < text.endIndex, text[cursor] == ":" else { return nil }
            cursor = skippingWhitespace(in: text, from: text.index(after: cursor))
            guard let valueEnd = endOfValue(in: text, from: cursor) else { return nil }

            members.append(Member(name: name, range: keyStart..<valueEnd))
            index = valueEnd
        }
    }

    /// Adds `"name": value` to the object at `start`, or replaces it when a
    /// member of that name is already there.
    ///
    /// The value is rendered by the caller and inserted verbatim, indented to
    /// match whatever the file already uses.
    static func upsert(
        member name: String,
        value: String,
        in text: String,
        objectAt start: String.Index
    ) -> String? {
        guard let members = members(in: text, objectAt: start) else { return nil }
        let indent = indentation(in: text, objectAt: start, members: members)
        let rendered = "\"\(escaped(name))\": " + value.replacingOccurrences(
            of: "\n", with: "\n" + indent
        )

        if let existing = members.first(where: { $0.name == name }) {
            var out = text
            out.replaceSubrange(existing.range, with: rendered)
            return out
        }
        var out = text
        let insertion = members.isEmpty
            ? "\n\(indent)\(rendered)\n"
            : "\n\(indent)\(rendered),"
        out.insert(contentsOf: insertion, at: text.index(after: start))
        return out
    }

    /// Removes the member of that name, and the comma that joined it to its
    /// neighbours. `nil` when the object could not be read; the text unchanged
    /// when the member was not there.
    static func remove(
        member name: String,
        in text: String,
        objectAt start: String.Index
    ) -> String? {
        guard let members = members(in: text, objectAt: start) else { return nil }
        guard let target = members.first(where: { $0.name == name }) else { return text }

        // Take the separator with the member: the one before it if there is a
        // preceding member, otherwise the one after. Leaving either behind is
        // a trailing comma, which is not JSON.
        var lower = target.range.lowerBound
        var upper = target.range.upperBound
        if members.first?.name == name {
            var cursor = skippingWhitespace(in: text, from: upper)
            if cursor < text.endIndex, text[cursor] == "," {
                cursor = text.index(after: cursor)
                upper = cursor
            }
            // The first member owns the whitespace between it and the opening
            // brace: an insert put a newline and an indent there, and leaving
            // them is a blank line in somebody's config.
            let objectBody = text.index(after: start)
            while lower > objectBody, text[text.index(before: lower)].isWhitespace {
                lower = text.index(before: lower)
            }
            var out = text
            out.removeSubrange(lower..<upper)
            return out
        } else {
            var cursor = lower
            while cursor > text.startIndex {
                let previous = text.index(before: cursor)
                if text[previous] == "," { lower = previous; break }
                guard text[previous].isWhitespace else { break }
                cursor = previous
            }
        }
        // Whatever whitespace was between the removed member and the next one
        // belonged to the member; leaving it makes a blank hole in the file.
        while lower > text.startIndex {
            let previous = text.index(before: lower)
            guard text[previous] == " " || text[previous] == "\t" else { break }
            lower = previous
        }
        var out = text
        out.removeSubrange(lower..<upper)
        return out
    }

    // MARK: Scanning

    private static func skippingWhitespace(in text: String, from index: String.Index) -> String.Index {
        var cursor = index
        while cursor < text.endIndex, text[cursor].isWhitespace {
            cursor = text.index(after: cursor)
        }
        return cursor
    }

    /// The index just past the closing quote of the string starting at `index`.
    private static func endOfString(in text: String, from index: String.Index) -> String.Index? {
        var cursor = text.index(after: index)
        while cursor < text.endIndex {
            switch text[cursor] {
            case "\\":
                cursor = text.index(after: cursor)
                guard cursor < text.endIndex else { return nil }
            case "\"":
                return text.index(after: cursor)
            default:
                break
            }
            cursor = text.index(after: cursor)
        }
        return nil
    }

    /// The index just past the value starting at `index`.
    private static func endOfValue(in text: String, from index: String.Index) -> String.Index? {
        guard index < text.endIndex else { return nil }
        switch text[index] {
        case "\"":
            return endOfString(in: text, from: index)
        case "{", "[":
            var depth = 0
            var cursor = index
            while cursor < text.endIndex {
                switch text[cursor] {
                case "\"":
                    guard let end = endOfString(in: text, from: cursor) else { return nil }
                    cursor = end
                    continue
                case "{", "[":
                    depth += 1
                case "}", "]":
                    depth -= 1
                    if depth == 0 { return text.index(after: cursor) }
                default:
                    break
                }
                cursor = text.index(after: cursor)
            }
            return nil
        default:
            // A number, `true`, `false`, or `null`: everything up to the next
            // separator or the end of the enclosing container.
            var cursor = index
            while cursor < text.endIndex {
                let character = text[cursor]
                if character == "," || character == "}" || character == "]"
                    || character.isWhitespace {
                    return cursor
                }
                cursor = text.index(after: cursor)
            }
            return nil
        }
    }

    /// The indentation the file already uses for members of this object.
    private static func indentation(
        in text: String,
        objectAt start: String.Index,
        members: [Member]
    ) -> String {
        guard let first = members.first else { return "  " }
        var cursor = first.range.lowerBound
        var indent = ""
        while cursor > text.startIndex {
            let previous = text.index(before: cursor)
            let character = text[previous]
            guard character == " " || character == "\t" else { break }
            indent.append(character)
            cursor = previous
        }
        return indent.isEmpty ? "  " : indent
    }

    static func escaped(_ value: String) -> String {
        var out = ""
        for character in value {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\t": out += "\\t"
            case "\r": out += "\\r"
            default: out.append(character)
            }
        }
        return out
    }

    private static func unescaped(_ value: String) -> String {
        guard value.contains("\\") else { return value }
        let wrapped = "\"\(value)\""
        guard let data = wrapped.data(using: .utf8),
              let decoded = try? JSONSerialization.jsonObject(
                  with: data, options: [.fragmentsAllowed]
              ) as? String
        else { return value }
        return decoded
    }
}

// MARK: - Fenced blocks

/// A region of a text file that Auspex owns, marked so a person and a program
/// can both see where it starts and stops.
///
/// The fence is the whole contract with the user's file: Auspex writes inside
/// it, reads it to know whether it has already written, and removes exactly it
/// on uninstall. Nothing outside the two marker lines is ever touched — which
/// means a person can edit around the block, move it, or add their own notes
/// above it, and none of that confuses the installer.
public struct ConfigFence: Sendable, Equatable {
    /// The comment syntax of the file the fence lives in.
    public enum Comment: Sendable, Equatable {
        /// `# …` — TOML, shell, YAML.
        case hash
        /// `<!-- … -->` — Markdown and HTML. Markdown gets this rather than
        /// `#`, because `# >>> auspex >>>` in a Markdown file is a level-one
        /// heading: it would show up in the rendered document, in the table of
        /// contents, and in whatever the harness feeds its model.
        case html
    }

    public let comment: Comment
    /// The name inside the markers. One per thing Auspex installs, so an MCP
    /// registration and a protocol snippet in the same file do not fight.
    public let name: String

    public init(comment: Comment, name: String = "auspex") {
        self.comment = comment
        self.name = name
    }

    public var opening: String {
        switch comment {
        case .hash: "# >>> \(name) >>>"
        case .html: "<!-- >>> \(name) >>> -->"
        }
    }

    public var closing: String {
        switch comment {
        case .hash: "# <<< \(name) <<<"
        case .html: "<!-- <<< \(name) <<< -->"
        }
    }

    /// The whole block, ready to append.
    public func block(_ body: String) -> String {
        "\(opening)\n\(body)\n\(closing)\n"
    }

    /// The range of the existing block, markers included, or `nil`.
    ///
    /// The *first* opening marker and the first closing marker after it. A file
    /// that somehow has two blocks is repaired one install at a time rather
    /// than being rewritten wholesale.
    public func range(in text: String) -> Range<String.Index>? {
        guard let open = text.range(of: opening),
              let close = text.range(of: closing, range: open.upperBound..<text.endIndex)
        else { return nil }
        // Take the newline after the closing marker too, so installing and
        // uninstalling repeatedly does not accumulate blank lines.
        var upper = close.upperBound
        if upper < text.endIndex, text[upper] == "\n" { upper = text.index(after: upper) }
        return open.lowerBound..<upper
    }

    /// What is inside the block right now, if there is one.
    public func body(in text: String) -> String? {
        guard let open = text.range(of: opening),
              let close = text.range(of: closing, range: open.upperBound..<text.endIndex)
        else { return nil }
        return String(text[open.upperBound..<close.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text with the block replaced, or appended when there is none.
    ///
    /// Idempotent: installing twice produces the same file the second time as
    /// the first, byte for byte.
    /// The one byte this writes outside its own region is a final newline on a
    /// file that did not end with one. Appending a fenced block to a
    /// half-finished last line would be worse — but it is the single respect in
    /// which ``removing(from:)`` restores the file's *content* rather than its
    /// exact bytes, and it is worth knowing.
    public func applying(_ body: String, to text: String) -> String {
        let block = block(body)
        if let range = range(in: text) {
            var out = text
            out.replaceSubrange(range, with: block)
            return out
        }
        if text.isEmpty { return block }
        var out = text
        if !out.hasSuffix("\n") { out += "\n" }
        // One blank line between their content and ours. It is part of the
        // region: `removing(from:)` takes exactly it back.
        return out + "\n" + block
    }

    /// The text with the block removed, and the blank line it was separated by.
    ///
    /// Exact, with the single exception ``applying(_:to:)`` names.
    public func removing(from text: String) -> String {
        guard let range = range(in: text) else { return text }
        var out = text
        out.removeSubrange(range)
        // Exactly one: any further blank lines were already there.
        if out.hasSuffix("\n\n") { out.removeLast() }
        return out
    }
}
