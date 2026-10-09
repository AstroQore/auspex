#!/usr/bin/env python3
"""Fail when Auspex's UI grows a hardcoded user-facing string.

Every word Auspex shows a person comes from the `auspex-i18n` catalogue
through the generated `L10n` API. This lint is what keeps it that way: a
`Text("Refresh")` anywhere under `Sources/AuspexApp` is an error at
`swift test` time rather than something a Chinese-language screenshot finds
months later.

Ported from AstroQore/vibe-bar's `Scripts/lint_localization.py`, which
learned the hard way that a regex over a line reports clean while the screen
shows English. So this scans the file properly: a small Swift lexer walks
every string literal, tracking the enclosing call and the argument label it
sits under. A literal is user-facing when the call it belongs to renders
text — a SwiftUI initializer, a text modifier, or one of this codebase's own
label-producing helpers, which are *derived from the source* rather than
listed here so the list cannot go stale — or when it is the value of a
member that exists to produce copy (`var title: String { "…" }`), and when
its argument label is not one of the identifier-shaped ones (`systemImage:`
is an SF Symbol, never copy).

What is allowed, and why each is not a loophole:

  * A term in auspex-i18n's `catalog/_glossary.json` — harness, company and
    product names (Claude Code, Codex, Cursor, MCP…). They are identifiers,
    not copy, and translating one makes two surfaces disagree about what a
    thing is called. The list is data so the app, the lint and a translator
    all read one file.
  * A literal with no letters at all: "·", "—", "%", "→", "".
  * A URL or a bare filesystem path.
  * A per-file exception in `ALLOWED`, each of which carries its reason.
  * A file in `EXEMPT`, each of which carries its reason. That list is for
    files with no UI at all — CLI output, the MCP protocol surface, the
    demo's fabricated data — never for a view that is merely awkward.

Run:
    Scripts/lint_localization.py            # report and exit non-zero
    Scripts/lint_localization.py --list     # the files it scans
    Scripts/lint_localization.py --exempt   # the files it skips, each with a reason
    Scripts/lint_localization.py --scan F   # findings in one arbitrary file
"""
import json
import os
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
APP_SOURCES = ROOT / "Sources/AuspexApp"


def _dependency_root(identity: str):
    """Where SwiftPM put a dependency's sources, whatever mode it is in.

    A tagged pin lands in `.build/checkouts/<name>`; a package in edit mode
    lives under `Packages/`; a local `path:` dependency is wherever that path
    points. `.build/workspace-state.json` records all three, so it is read
    rather than guessed.
    """
    state_file = ROOT / ".build/workspace-state.json"
    try:
        state = json.loads(state_file.read_text())
    except (OSError, ValueError):
        state = {}
    for dependency in state.get("object", {}).get("dependencies", []):
        reference = dependency.get("packageRef", {})
        if reference.get("identity") != identity:
            continue
        kind = dependency.get("state", {}).get("name")
        subpath = dependency.get("subpath", identity)
        if kind == "fileSystem":
            return pathlib.Path(reference.get("location", ""))
        if kind == "edited":
            edited = dependency.get("state", {}).get("path")
            return pathlib.Path(edited) if edited else ROOT / "Packages" / subpath
        return ROOT / ".build/checkouts" / subpath
    return ROOT / ".build/checkouts" / identity


# The never-translate list is data in the shared catalogue repository, which
# SwiftPM fetches on the first `swift build`; the lint reads it from there so
# the app cannot carry a second copy that drifts. `AUSPEX_I18N_CATALOG` names
# the catalogue directory of a local checkout instead.
GLOSSARY = (
    pathlib.Path(os.environ["AUSPEX_I18N_CATALOG"]) / "_glossary.json"
    if os.environ.get("AUSPEX_I18N_CATALOG")
    else _dependency_root("auspex-i18n") / "catalog/_glossary.json"
)

# Files under Sources/AuspexApp that render nothing a person reads in the
# app's own UI, so their literals are not copy. Each carries its reason. A
# view never belongs here: a view that is hard to migrate is a view that
# needs migrating.
EXEMPT = {
    "Sources/AuspexApp/main.swift":
        "command-line dispatch: `--help` text and renderer diagnostics go to "
        "stdout/stderr for a person at a terminal or a script, in English, "
        "like every other CLI's",
    "Sources/AuspexApp/MCP/AuspexStdioBridge.swift":
        "the MCP stdio bridge: protocol frames and bridge diagnostics",
    "Sources/AuspexApp/MCP/AppMCPHost.swift":
        "the MCP host: tool descriptions and results are a protocol surface "
        "an agent parses, fixed in English",
    "Sources/AuspexApp/Demo/DemoEventSource.swift":
        "the demo's fabricated sessions: prompts, titles and tool targets are "
        "sample data standing in for what a real harness would record",
    # The offscreen renderers behind `--render-*`. The views they photograph
    # are scanned in their own files; what these files spell themselves is
    # the command's stdout summary, its error descriptions, and the legend of
    # a developer filmstrip — CLI output, like `main.swift`.
    "Sources/AuspexApp/Crew/CrewMotionRenderer.swift":
        "offscreen renderer: CLI summary, errors, and a developer filmstrip's legend",
    "Sources/AuspexApp/Crew/CrewSnapshotRenderer.swift":
        "offscreen renderer: CLI summary and errors",
    "Sources/AuspexApp/Demo/ContextPopoverRenderer.swift":
        "offscreen renderer: CLI summary and errors",
    "Sources/AuspexApp/Demo/MapSnapshotRenderer.swift":
        "offscreen renderer: CLI summary and errors",
    "Sources/AuspexApp/Demo/TrajectorySnapshotRenderer.swift":
        "offscreen renderer: CLI summary and errors",
    "Sources/AuspexApp/Demo/WindowSnapshotRenderer.swift":
        "offscreen renderer: CLI summary and errors",
}


def scanned_files():
    """Every Swift file under Sources/AuspexApp that is not exempt."""
    files = []
    for path in sorted(APP_SOURCES.rglob("*.swift")):
        relative = str(path.relative_to(ROOT))
        if relative in EXEMPT:
            continue
        files.append(relative)
    return files


MIGRATED = scanned_files()


class Failure(SystemExit):
    pass


# ---------------------------------------------------------------- lexing

IDENTIFIER = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")


class Literal:
    __slots__ = ("text", "line", "callee", "is_modifier", "receiver", "label")

    def __init__(self, text, line, callee, is_modifier, receiver, label):
        self.text = text
        self.line = line
        self.callee = callee
        self.is_modifier = is_modifier
        self.receiver = receiver
        self.label = label


def scan(source: str):
    """Every string literal in `source`, with the call context around it.

    Handles line and (nested) block comments, triple-quoted multi-line strings,
    `#"…"#` raw strings, escapes, and `\\(…)` interpolation — an
    interpolated literal is consumed whole rather than recursed into, so
    `"\\(n) left"` is reported as one literal and still flagged.
    """
    literals = []
    # One frame per open `(`; a frame records what is being called and the
    # argument label the cursor currently sits under.
    frames = [{"callee": None, "modifier": False, "receiver": None,
               "label": None, "expect": False}]
    index = 0
    line = 1
    length = len(source)
    block_depth = 0
    # The source with every comment character blanked as the scan passes it,
    # which is what the callee lookup walks backwards over. Without it a
    # comment ending in a full stop — "…see ``CommandPalette``." on the line
    # above `Button("Go to Task…")` — reads as `.Button(…)`, a modifier, and
    # the literal slips through. (Found porting this lint from vibe-bar.)
    code = list(source)

    while index < length:
        char = source[index]

        if char == "\n":
            line += 1
            index += 1
            continue

        if block_depth:
            if source.startswith("*/", index):
                block_depth -= 1
                code[index] = code[index + 1] = " "
                index += 2
            elif source.startswith("/*", index):
                block_depth += 1
                code[index] = code[index + 1] = " "
                index += 2
            else:
                code[index] = " "
                index += 1
            continue

        if source.startswith("//", index):
            end = source.find("\n", index)
            end = length if end == -1 else end
            code[index:end] = " " * (end - index)
            index = end
            continue

        if source.startswith("/*", index):
            block_depth = 1
            code[index] = code[index + 1] = " "
            index += 2
            continue

        # Raw strings: #"…"#, ##"…"##
        if char == "#":
            hashes = 0
            probe = index
            while probe < length and source[probe] == "#":
                hashes += 1
                probe += 1
            if probe < length and source[probe] == '"':
                start_line = line
                terminator = '"' + "#" * hashes
                if source.startswith('"""', probe):
                    terminator = '"""' + "#" * hashes
                    probe += 3
                else:
                    probe += 1
                end = source.find(terminator, probe)
                end = length if end == -1 else end
                body = source[probe:end]
                line += body.count("\n")
                literals.append(_literal(body, start_line, frames))
                index = end + len(terminator)
                continue

        if source.startswith('"""', index):
            start_line = line
            end = source.find('"""', index + 3)
            end = length if end == -1 else end
            body = source[index + 3:end]
            line += body.count("\n")
            literals.append(_literal(body, start_line, frames))
            index = end + 3
            continue

        if char == '"':
            start_line = line
            index += 1
            body = []
            depth = 0  # interpolation nesting
            while index < length:
                current = source[index]
                if current == "\\" and index + 1 < length:
                    if source[index + 1] == "(":
                        depth += 1
                        body.append("\\(")
                        index += 2
                        continue
                    body.append(source[index:index + 2])
                    index += 2
                    continue
                if depth:
                    if current == "(":
                        depth += 1
                    elif current == ")":
                        depth -= 1
                    elif current == "\n":
                        line += 1
                    body.append(current)
                    index += 1
                    continue
                if current == '"':
                    index += 1
                    break
                if current == "\n":
                    line += 1
                body.append(current)
                index += 1
            literals.append(_literal("".join(body), start_line, frames))
            continue

        if char == "(":
            callee, modifier, receiver = _callee_before(code, index)
            frames.append(
                {"callee": callee, "modifier": modifier, "receiver": receiver,
                 "label": None, "expect": True}
            )
            index += 1
            continue

        if char == ")":
            if len(frames) > 1:
                frames.pop()
            index += 1
            continue

        if char in "[{":
            frames.append(
                {"callee": None, "modifier": False, "receiver": None,
                 "label": None, "expect": False}
            )
            index += 1
            continue

        if char in "]}":
            if len(frames) > 1:
                frames.pop()
            index += 1
            continue

        if char == ",":
            frames[-1]["label"] = None
            frames[-1]["expect"] = True
            index += 1
            continue

        match = IDENTIFIER.match(source, index)
        if match:
            if frames[-1]["expect"]:
                after = match.end()
                while after < length and source[after] in " \t":
                    after += 1
                if after < length and source[after] == ":" and not source.startswith("::", after):
                    frames[-1]["label"] = match.group(0)
                frames[-1]["expect"] = False
            index = match.end()
            continue

        if char not in " \t":
            frames[-1]["expect"] = False
        index += 1

    return literals


def _literal(text, line, frames):
    frame = frames[-1]
    return Literal(
        text, line, frame["callee"], frame["modifier"], frame["receiver"],
        frame["label"],
    )


def _callee_before(source, paren_index):
    """`(name, followed_a_dot, receiver)` for the call opening at `(`."""
    probe = paren_index - 1
    while probe >= 0 and source[probe] in " \t\n":
        probe -= 1
    end = probe + 1
    while probe >= 0 and (source[probe].isalnum() or source[probe] == "_"):
        probe -= 1
    name = "".join(source[probe + 1:end])
    if not name or not (name[0].isalpha() or name[0] == "_"):
        return None, False, None
    while probe >= 0 and source[probe] in " \t\n":
        probe -= 1
    if probe < 0 or source[probe] != ".":
        return name, False, None
    probe -= 1
    while probe >= 0 and source[probe] in " \t\n":
        probe -= 1
    end = probe + 1
    while probe >= 0 and (source[probe].isalnum() or source[probe] == "_"):
        probe -= 1
    return name, True, "".join(source[probe + 1:end]) or None


# ------------------------------------------------------------- the rules

# SwiftUI initializers whose leading arguments are text the user reads.
UI_CALLS = {
    "Text", "Button", "Toggle", "Picker", "Label", "TextField", "SecureField",
    "TextEditor", "Section", "Stepper", "Link", "Menu", "GroupBox",
    "DisclosureGroup", "NavigationLink", "Slider", "ProgressView", "Tab",
    "Alert", "Toast",
}

# Text-bearing modifiers. `.tag` is deliberately absent: it carries a
# selection identity, not copy.
UI_MODIFIERS = {
    "help", "navigationTitle", "navigationSubtitle", "alert",
    "confirmationDialog", "accessibilityLabel", "accessibilityValue",
    "accessibilityHint", "searchable", "badge",
}

# Argument labels this codebase passes copy through, whatever the callee.
COPY_ARGUMENTS = {
    "title", "subtitle", "message", "help", "caption", "placeholder",
    "titleOverride", "emptyMessage", "emptyMessageOverride", "label",
    "heatmapTitleOverride", "prompt", "detail", "headline", "verdict",
    "detected", "web", "missing", "text", "value", "summary", "footer",
    "toolName",
}

# Argument labels that are never copy, even inside a text-rendering call.
# `systemImage:` is an SF Symbol name; `tag:`/`id:` are identities.
IDENTIFIER_ARGUMENTS = {
    "systemImage", "systemName", "symbol", "image", "icon", "id", "tag", "key", "forKey", "table",
    "bundle", "forResource", "withExtension", "named", "identifier",
    "separator", "format", "comment", "scheme", "host", "path", "rawValue",
    "toolNameOverride", "forGroupName", "bucketId", "accountId", "command",
}

# Return types that mark a helper as producing something the user reads.
VIEW_RETURNS = re.compile(r"->\s*(some\s+View|Text|AnyView|String|LocalizedStringKey)\b")


def _resolve(relative) -> pathlib.Path:
    path = pathlib.Path(relative)
    return path if path.is_absolute() else ROOT / path


def derived_helpers(files) -> set:
    """This codebase's own label-producing helpers, read out of the source.

    `sectionLabel("REAL TOKENS · SELECTED RANGE")` is as much a visible
    string as `Text(...)`, and there are enough of these — `detailText`,
    `hintLabel`, `metric`, `summaryRow`, `messageRow` — that a hand-kept
    list would be stale within a release. Any function that takes a
    `String` and returns a view or a string is treated as one.
    """
    helpers = set()
    for relative in files:
        path = _resolve(relative)
        if not path.exists():
            continue
        source = path.read_text()
        for match in re.finditer(r"\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>]*>)?\s*\(", source):
            depth, index = 1, match.end()
            while index < len(source) and depth:
                if source[index] == "(":
                    depth += 1
                elif source[index] == ")":
                    depth -= 1
                index += 1
            parameters = source[match.end():index - 1]
            tail = source[index:index + 80]
            if "String" in parameters and VIEW_RETURNS.search(tail):
                helpers.add(match.group(1))
    # A function *named* for an identifier builds identity, not copy, however
    # much its signature looks like a label helper's. `OverviewQuotaCurve.id`
    # takes three strings and returns one, so inferring from the shape alone
    # made every `id("blank-\(n)")` in the manifest a finding. These are the
    # same names `IDENTIFIER_ARGUMENTS` already trusts as an argument label.
    return helpers - IDENTIFIER_ARGUMENTS


# This codebase's own views that print a `String` property verbatim:
# `MetaField(key: "turns", …)` draws "turns" on a card, and `key:` is in
# `IDENTIFIER_ARGUMENTS` because everywhere else it names something. Derived
# from the source like the helpers: a `struct X: View` with a stored
# `String` property of a copy-shaped name takes copy under that label, and
# under no label at all when it also declares `init(_ x: String…)`.
VIEW_COPY_PROPERTIES = {"title", "label", "text", "key", "name", "detail",
                        "subtitle", "caption", "message", "heading"}


def derived_view_types(files) -> dict:
    types = {}
    for relative in files:
        path = _resolve(relative)
        if not path.exists():
            continue
        source = path.read_text()
        for match in re.finditer(
            r"\bstruct\s+([A-Z]\w*)(?:<[^>]*>)?\s*:\s*[^{]*\bView\b[^{]*\{", source
        ):
            depth, index = 1, match.end()
            while index < len(source) and depth:
                if source[index] == "{":
                    depth += 1
                elif source[index] == "}":
                    depth -= 1
                index += 1
            body = source[match.end():index]
            labels = set()
            for prop in re.finditer(
                r"^\s*(?:let|var)\s+([a-z]\w*)\s*:\s*String\??\s*(?:=|$)", body, re.M
            ):
                if prop.group(1) in VIEW_COPY_PROPERTIES:
                    labels.add(prop.group(1))
            if labels and re.search(r"\binit\(\s*_\s+\w+\s*:\s*String", body):
                labels.add(None)
            if labels:
                types.setdefault(match.group(1), set()).update(labels)
        # `extension X where …` initialisers with an unlabeled String.
        for match in re.finditer(r"\bextension\s+([A-Z]\w*)[^{]*\{", source):
            tail = source[match.end():match.end() + 400]
            if re.search(r"\binit\(\s*_\s+\w+\s*:\s*String", tail):
                types.setdefault(match.group(1), set()).add(None)
    return types


VIEW_TYPES: dict = {}


# Members whose value *is* copy. A literal returned from one of these is
# rendered without ever being passed to anything, which is how
# `case .up: return "Up"` sat in a migrated file, beside four `L10n.Status`
# calls in the same switch, and the lint still reported the file clean.
#
# This is the same lesson as adding producing types to the manifest, one
# level deeper: guarding the *call* does not guard the *return*. Names that
# build identity rather than copy stay out — `id`, `rawValue`, `iconName`,
# `key`, `path` — and so does anything `IDENTIFIER_ARGUMENTS` already
# distrusts as an argument label.
COPY_MEMBERS = {
    "label", "title", "subtitle", "caption", "detail", "description",
    "displayName", "summary", "message", "prompt", "placeholder", "hint",
    "shortLabel", "headline", "text", "tooltip", "help",
} - IDENTIFIER_ARGUMENTS


def copy_member_spans(source: str):
    """Lines where a member that exists to produce copy returns a literal."""
    spans = []
    pattern = re.compile(
        r"\b(?:var|func)\s+([A-Za-z_]\w*)\s*(?:\([^)]*\))?\s*"
        r"(?:async\s+)?(?:throws\s+)?(?:->\s*)?:?\s*(?:->\s*)?String\b"
    )
    for match in pattern.finditer(source):
        if match.group(1) not in COPY_MEMBERS:
            continue
        brace = source.find("{", match.end())
        # A stored `var detail: String?` has no body; taking the next brace
        # in the file would swallow whatever member happens to follow it.
        if brace == -1 or source[match.end():brace].strip(" \t\n?!"):
            continue
        depth, index = 1, brace + 1
        while index < len(source) and depth:
            if source[index] == "{":
                depth += 1
            elif source[index] == "}":
                depth -= 1
            index += 1
        spans.append((brace, index))
    # Only what the member *produces*. A copy-producing function still
    # matches machine-readable values to decide what to say — a switch over
    # `"network_timeout"` is reading a code, not printing one — so flagging
    # every literal in the body reported the codes and buried the copy.
    lines = set()
    for start, end in spans:
        body = source[start:end]
        # `return "x"`, `?? "x"`, and the implicit single-expression form
        # `var label: String { "x" }` / `case .a: "x"`, which is how most of
        # this codebase actually writes them. Requiring the keyword closed
        # the gap only for the half that spells it out.
        for match in re.finditer(r'(?:return|\?\?|\{|:)\s*"', body):
            lines.add(source.count("\n", 0, start + match.start()) + 1)
    return lines


LETTER = re.compile(r"[A-Za-z一-鿿]")


def without_interpolations(text: str) -> str:
    """Drop every `\\(…)` segment, keeping the literal's own characters.

    `scan` consumes an interpolated literal whole, so the reported text
    carries the *expression* inside each `\\(…)` — Swift identifiers, which
    look exactly like words to `LETTER`. That is what reported
    `"\\(base) · \\(accountQualifier)"` as copy: a separator joining two
    already-localized halves, whose only letters were variable names.

    Only the letters the literal spells itself are copy, so this removes
    the interpolations before that question is asked. `"\\(n) left"` still
    keeps its "left" and is still flagged — which is the whole point of
    consuming interpolated literals whole.
    """
    out, index, length = [], 0, len(text)
    while index < length:
        if text.startswith("\\(", index):
            start = index + 2
            depth, index = 1, start
            while index < length and depth:
                if text[index] == "(":
                    depth += 1
                elif text[index] == ")":
                    depth -= 1
                index += 1
            # The expression's identifiers are not copy, but a literal
            # inside it is: `Text("\\(ready ? \"Ready\" : \"Waiting\")")`
            # puts two English words on screen, and dropping the whole
            # segment made a migrated file pass while shipping both.
            out.extend(_quoted_runs(text[start:index - 1]))
            continue
        out.append(text[index])
        index += 1
    return "".join(out)


def _quoted_runs(expression: str) -> list:
    """The contents of every double-quoted run in an interpolated expression."""
    runs, index, length = [], 0, len(expression)
    while index < length:
        if expression[index] == "\\" :
            index += 2
            continue
        if expression[index] != '"':
            index += 1
            continue
        index += 1
        body = []
        while index < length and expression[index] != '"':
            if expression[index] == "\\" and index + 1 < length:
                index += 1
            body.append(expression[index])
            index += 1
        index += 1
        runs.append("".join(body))
    return runs

# Per-file exceptions: a literal that reads like copy but is not, keyed by
# the reason it is exempt. Kept short on purpose — most cases are better
# answered by the glossary (a name) or by `IDENTIFIER_ARGUMENTS` (an
# argument that never carries copy), and an exception that names one file is
# the thing that quietly grows into a second, unreviewed allowlist.
ALLOWED: dict = {
    "a key cap: the key is engraved Esc, and every language reads the "
    "engraving rather than a translation of it": {
        "Board/BoardView.swift": {"Esc"},
    },
    "`pid`, the kernel's own name for a process id, printed beside the "
    "number the way `ps` prints it — a column header in every language": {
        "Board/SessionCard.swift": {"pid \\(pid)"},
        "Trace/SessionTraceView.swift": {"pid \\(pid)"},
    },
    "an MCP tool's protocol name: `notify` is what an agent calls and what "
    "its author greps for": {
        "Now/NowView.swift": {"notify · \\(message)"},
    },
    "a unit after a number — `px` reads the same on every Mac": {
        "Settings/CharactersSettingsView.swift": {"32 px", "\\(package.cell) px"},
    },
    "the offscreen scene renderer's fabricated crowd and its CLI errors — "
    "sample data and diagnostics, like the rest of the `--render-*` path": {
        "Scene/SceneContainerView.swift": {
            "Fleet worker \\(index + 1)",
            "the board produced no desks to draw",
            "SpriteKit could not render the scene offscreen",
            "the rendered image could not be encoded as PNG",
        },
    },
    "a version tag, spelled the way the release is tagged": {
        "Tasks/TaskDetailView.swift": {"v\\(version)"},
    },
    "command-line flags the launch options are parsed from": {
        "AppEnvironment.swift": {"--view", "--appearance", "--demo-scale"},
    },
    "a command a person types into Terminal: the words are the program's "
    "arguments, and a translated one would not run": {
        "Board/BoardEmptyState.swift": {"Auspex.app/Contents/MacOS/Auspex --demo"},
    },
}


def glossary_terms() -> set:
    document = json.loads(GLOSSARY.read_text())
    terms = set()
    for field, value in document.items():
        if field in {"schema", "note", "rules"} or not isinstance(value, list):
            continue
        # The shared catalogue spells each entry as {"term": …, "kind": …};
        # a bare string is accepted too, for a hand-written list.
        for item in value:
            term = item.get("term") if isinstance(item, dict) else item
            if isinstance(term, str) and term:
                terms.add(term)
    return terms


URL = re.compile(r"^[a-z][a-z0-9+.-]*://\S*$|^~?/[\w./~-]*$")


# An SF Symbol's name: dotted lower-case words, `chevron.left`,
# `arrow.triangle.2.circlepath`. Passed unlabelled to this codebase's own
# helpers often enough that guessing the label would miss them.
SF_SYMBOL = re.compile(r"^[a-z0-9]+(\.[a-z0-9]+)+$")

# Escape sequences spell letters (`\n`) that are not words.
ESCAPE = re.compile(r"\\[nrt0\"'\\]")


def is_allowed(text: str, terms: set, path: str) -> bool:
    stripped = text.strip()
    if not stripped or not LETTER.search(ESCAPE.sub("", without_interpolations(stripped))):
        return True
    if SF_SYMBOL.match(stripped):
        return True
    # A URL or a bare filesystem path is an address, not a sentence. No
    # language spells `https://` differently.
    if URL.match(stripped):
        return True
    if stripped in terms:
        return True
    # A glossary term with punctuation or a separator around it — "Claude ·",
    # "AntiGravity:" — is still the term, not a sentence about it.
    if stripped.strip(" ·:—-…()[]") in terms:
        return True
    for _reason, files in ALLOWED.items():
        for suffix, literals in files.items():
            if str(path).endswith(suffix) and stripped in literals:
                return True
    return False


# Receivers whose string arguments are identifiers, not copy. `L10n` is the
# obvious one: its argument *is* a catalog key.
IDENTIFIER_RECEIVERS = {"L10n", "Bundle", "UserDefaults", "NSLocalizedString"}


# Display formatting that asks the *process* locale instead of the app's.
# `Locale.current` is the system's language, and the Language setting is
# not; a time formatted against it drops "3:04:05 PM" into the middle of a
# Chinese screen. Everything the user reads goes through `AppLocale`.
#
# A bare `DateFormatter()` is not on the list: the ones here are fixed machine
# formats (`HH:mm:ss` on `en_US_POSIX`), which read the same in every
# language. `Sources/AuspexApp/Localization/` is where the locale-bound
# formatters are built, so it is the one directory these rules skip.
FORMATTING_HOME = "Sources/AuspexApp/Localization/"
FORMATTING = [
    (re.compile(r"\bRelativeDateTimeFormatter\(\)"),
     "RelativeDateTimeFormatter() — use AppLocale.relativeDateTimeFormatter"),
    (re.compile(r"\.formatted\(date:"), ".formatted(date:time:) — use AppLocale.time / AppLocale.date"),
    (re.compile(r"\bLocale\.current\b"), "Locale.current — the system's language, not the app's"),
]


def strip_comments(line: str) -> str:
    """Blank out a trailing `//` comment without touching one inside a string."""
    in_string = False
    index = 0
    while index < len(line):
        character = line[index]
        if character == "\\" and in_string:
            index += 2
            continue
        if character == '"':
            in_string = not in_string
        elif not in_string and line.startswith("//", index):
            return line[:index]
        index += 1
    return line


def formatting_findings(relative, source: str):
    """Display formatting that bypasses `AppLocale`, outside comments."""
    found = []
    if str(relative).startswith(FORMATTING_HOME):
        return found
    stripped = []
    block = False
    for line in source.splitlines():
        if block:
            if "*/" in line:
                line, block = line.split("*/", 1)[1], False
            else:
                stripped.append("")
                continue
        if "/*" in line:
            head, _, tail = line.partition("/*")
            if "*/" in tail:
                line = head + tail.split("*/", 1)[1]
            else:
                line, block = head, True
        line = strip_comments(line)
        stripped.append("" if line.lstrip().startswith("///") else line)
    for number, line in enumerate(stripped, start=1):
        for pattern, reason in FORMATTING:
            if pattern.search(line):
                found.append((number, reason))

    # A number / percent / currency style needs `.locale(AppLocale.current)`
    # somewhere in its own argument list. That span has to be found by
    # walking the parentheses — a regex cannot balance them, and the first
    # attempt reported a call that was already correct, which is exactly the
    # kind of false positive that gets a lint switched off.
    joined = "\n".join(stripped)
    for match in re.finditer(r"\.formatted\(\s*\.(?:number|percent|currency)", joined):
        start = joined.index("(", match.start() + len(".formatted") - 1)
        depth, index = 0, start
        while index < len(joined):
            if joined[index] == "(":
                depth += 1
            elif joined[index] == ")":
                depth -= 1
                if depth == 0:
                    break
            index += 1
        if ".locale(" not in joined[start:index]:
            found.append((
                joined.count("\n", 0, match.start()) + 1,
                "a number/percent/currency style without .locale(AppLocale.current)",
            ))
    found += frozen_language_findings(joined)
    return found


# A stored `static` whose value comes out of the catalog is frozen in whatever
# language the process launched in. `let` is the whole bug — the initializer
# runs once, lazily, and never again — and `var` with an `=` is the same
# storage. A computed `static var { ... }` is the fix and is deliberately not
# matched, which is why this looks for the `=` rather than for the keyword.
FROZEN_STATIC = re.compile(
    r"\bstatic\s+(?:let|var)\s+[A-Za-z_]\w*\s*(?::[^=\n]+)?=", re.M
)


def _references_catalog_eagerly(initializer: str) -> bool:
    """A catalog reference in `initializer` that runs when the static does.

    Brace depth is the whole test: inside `{ ... }` the expression is a
    closure body that runs per call, which is exactly how a table of
    `{ L10n.… }` closures stays correct while looking like the bug.
    """
    depth = 0
    index = 0
    while index < len(initializer):
        character = initializer[index]
        if character == "{":
            depth += 1
        elif character == "}":
            depth = max(0, depth - 1)
        elif depth == 0:
            if initializer.startswith("L10n.", index):
                return True
        index += 1
    return False


def frozen_language_findings(source: str):
    """A `static let` holding a localized value: frozen at launch language.

    `AppLocale` learned this once already — twenty `static let` formatters
    kept the language they were built in until relaunch — and the same defect
    reappears wherever a cache holds a *string* out of the catalog. Two of
    those shipped in this batch (the chart's duration pills, the cost chart's
    bucket-width labels) and neither was visible to any other rule here.

    The span searched is the initializer, balanced by braces and brackets as
    well as parentheses, because the values that actually do this are array
    and dictionary literals spanning many lines.
    """
    found = []
    opening = {"(": ")", "[": "]", "{": "}"}
    for match in FROZEN_STATIC.finditer(source):
        index = match.end()
        # Walk to the end of the initializer: to the matching close of
        # whatever bracket it opens with, or to the end of the line.
        while index < len(source) and source[index] in " \t":
            index += 1
        end = index
        if index < len(source) and source[index] in opening:
            depth = 0
            while end < len(source):
                if source[end] in opening:
                    depth += 1
                elif source[end] in opening.values():
                    depth -= 1
                    if depth == 0:
                        end += 1
                        break
                end += 1
        else:
            end = source.find("\n", index)
            end = len(source) if end == -1 else end
        initializer = source[index:end]
        # A value wrapped in a closure is *deferred*, not frozen:
        # `["weekly": { L10n.Quota.groupWeekly }]` resolves on every call and
        # is the fix, not the bug. So only a catalog reference that is
        # evaluated eagerly — outside any braces — counts.
        if not _references_catalog_eagerly(initializer):
            continue
        found.append((
            source.count("\n", 0, match.start()) + 1,
            "a stored static holding a localized value — frozen at launch "
            "language; make it a computed property",
        ))
    return found


def findings_for(relative, helpers: set, terms: set):
    path = _resolve(relative)
    source = path.read_text()
    # A generated file is never hand-migrated, and its key literals would
    # otherwise read as copy passed to a one-argument String helper.
    if "Generated by Scripts/" in source[:400]:
        return []
    found = []
    copy_spans = copy_member_spans(source)
    for literal in scan(source):
        if literal.receiver in IDENTIFIER_RECEIVERS:
            continue
        callee = literal.callee
        renders = (
            (callee in UI_CALLS and not literal.is_modifier)
            or (callee in UI_MODIFIERS and literal.is_modifier)
            or (callee in helpers)
        )
        if literal.label in COPY_ARGUMENTS:
            renders = True
        if literal.label in IDENTIFIER_ARGUMENTS:
            renders = False
        if callee in VIEW_TYPES and not literal.is_modifier and literal.label in VIEW_TYPES[callee]:
            renders = True
        if not renders:
            # ...unless it is the value of a member that exists to produce
            # copy, where nothing has to pass it anywhere for a user to read
            # it.
            if literal.line not in copy_spans:
                continue
            # Reachable, but `systemImage:` and its kin still never carry
            # copy — the copy-member rule adds a way in, not an exemption
            # from the question already answered here.
            if literal.label in IDENTIFIER_ARGUMENTS:
                continue
        if is_allowed(literal.text, terms, relative):
            continue
        where = f"{callee or '?'}(" + (f"{literal.label}:" if literal.label else "") + "…)"
        found.append((literal.line, literal.text, where))
    for line, reason in formatting_findings(relative, source):
        found.append((line, reason, "display formatting"))
    return found


def main() -> int:
    if "--list" in sys.argv[1:] and "--scan" not in sys.argv[1:]:
        print("\n".join(MIGRATED))
        return 0
    if "--exempt" in sys.argv[1:]:
        print("\n".join(sorted(EXEMPT)))
        return 0

    arguments = sys.argv[1:]
    if "--scan" in arguments:
        # Point the scanner at one arbitrary file and print what it finds,
        # one `line<TAB>literal` per row. `LocalizationLintTests` uses this
        # to check the scanner against a fixture of the shapes that used to
        # slip past it — a lint nothing tests is a lint that is trusted for
        # the wrong reasons.
        target = pathlib.Path(arguments[arguments.index("--scan") + 1])
        helpers = derived_helpers(MIGRATED) | derived_helpers([target])
        VIEW_TYPES.update(derived_view_types(MIGRATED + [target]))
        for line, text, _where in findings_for(target, helpers, glossary_terms()):
            print(f"{line}\t{text}")
        return 0

    helpers = derived_helpers(MIGRATED)
    VIEW_TYPES.update(derived_view_types(MIGRATED))
    if "--helpers" in arguments:
        print("\n".join(sorted(helpers)))
        return 0

    terms = glossary_terms()
    findings = []
    for relative in MIGRATED:
        if not (ROOT / relative).exists():
            findings.append((relative, 0, "listed as migrated but does not exist", ""))
            continue
        for line, text, where in findings_for(relative, helpers, terms):
            findings.append((relative, line, f'"{text}"', where))

    if findings:
        print(
            "lint_localization: user-facing literals that do not go through "
            "L10n\n",
            file=sys.stderr,
        )
        for relative, line, detail, where in findings:
            print(f"  {relative}:{line}: {detail}  in {where}", file=sys.stderr)
        print(
            f"\n{len(findings)} finding(s). Either route the string through "
            f"L10n (add the key to auspex-i18n's catalog/en.json and zh-Hans.json, "
            f"tag a release and bump the pin in Package.swift), or — if it is a "
            f"harness, company or product name — add it to "
            f"its catalog/_glossary.json.",
            file=sys.stderr,
        )
        return 1
    print(
        f"lint_localization: {len(MIGRATED)} file(s) under Sources/AuspexApp clean "
        f"({len(helpers)} label-producing helpers derived from the source)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
