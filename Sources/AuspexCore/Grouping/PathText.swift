import Foundation

/// Path arithmetic that does not leave an `NSString` behind.
///
/// ## Why this exists, in one profile line
///
/// `NSString`'s path methods are the obvious way to take a path apart, and
/// every one of them hands back a *bridged* Swift string — an `NSPathStore2`
/// wearing a `String` — rather than a native one. A bridged string is fine to
/// carry and fine to draw. It is not fine to **compare**: `==` on two of them
/// cannot take the fast UTF-8 path, so it goes through
/// `_stringCompareSlow` and Unicode NFD/NFC normalisation, one scalar at a
/// time, through `-[NSPathStore2 characterAtIndex:]`.
///
/// That matters here because a path ends up on every ``BoardRow`` — as the
/// project name and as the working directory — and SwiftUI compares those
/// rows on every graph update. A `sample` of the window at `--demo-scale 12`
/// had `Unicode._NFDNormalizer._resume` and its neighbours as the single
/// largest block of self time on the main thread, underneath
/// `BoardRow.__derived_struct_equals`. The strings were being *normalised*, in
/// the render loop, to answer "did this card change".
///
/// So the two path operations the frame path actually performs are written out
/// in Swift, over native storage, and the one place a bridged string can still
/// arrive from Foundation goes through ``native(_:)``. Four lines each, and
/// the comparison they enable is a `memcmp`.
public enum PathText {
    /// The last component of a path, natively.
    ///
    /// Matches `NSString.lastPathComponent` for everything a project key can
    /// be: `/a/b` → `b`, `/` → `/`, `b` → `b`, `` → ``. It deliberately does
    /// *not* collapse repeated separators or strip a trailing slash — the
    /// callers here do that themselves, and doing it twice is how two
    /// functions that agree today stop agreeing later.
    public static func lastComponent(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return path }
        let name = String(path[path.index(after: slash)...])
        return name.isEmpty ? path : name
    }

    /// The same string, guaranteed to be native Swift storage.
    ///
    /// For the boundaries where Foundation is the only thing that can answer —
    /// `standardizingPath`, most of all — and the answer then goes on to be
    /// compared a few hundred times a second. One pass over the UTF-8 here
    /// buys a `memcmp` at every comparison after it.
    ///
    /// A no-op for a string that is already native: Swift's small-string and
    /// native-storage forms round-trip through this without a copy worth
    /// measuring, and the check that would avoid it is not public API.
    public static func native(_ text: String) -> String {
        text.isEmpty ? text : String(decoding: Array(text.utf8), as: UTF8.self)
    }
}
