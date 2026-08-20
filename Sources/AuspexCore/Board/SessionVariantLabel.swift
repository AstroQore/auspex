import AgentSessionKit
import AgentSessionLive
import Foundation

/// The one word a card can add about *which flavour* of a harness a session
/// is, when the harness's own name does not already say it.
///
/// ``SessionIdentity/variant`` is a harness-internal string, and most of what
/// it holds is not something to put on a card: Codex writes its originator
/// there (`codex_cli_rs`, `codex_work_desktop`) and the board already says
/// "Codex" and "ChatGPT Work"; Cursor writes its composer mode; Grok Bot
/// writes `bot` next to a row headed "Grok Bot". Rendering those would be a
/// chip that repeats the harness badge beside it in the harness's own spelling.
///
/// Three of them are worth a chip, because each one changes what the session
/// *is* rather than restating what it is called:
///
/// | variant | chip | why it matters |
/// | --- | --- | --- |
/// | `auto-review:<root>` | `auto review` | not a person's session at all — Codex reviewing its own work |
/// | `cli` | `cli` | a command line — AntiGravity's `agy`, and whatever else spells it the same |
/// | `ide` | `ide` | an editor, which for AntiGravity has no way back in from a terminal |
///
/// `cli` and `ide` are taken at face value whatever harness wrote them: they
/// are the two values in the kit's own documentation of the field, they mean
/// the same thing everywhere, and a table keyed on harness *and* variant would
/// have to be extended before a new harness's honest `cli` could be shown.
///
/// Anything else answers `nil`. A curated list rather than a formatter,
/// because the failure mode of a formatter here is an internal identifier
/// shown to a person as though it meant something.
public enum SessionVariantLabel {
    /// What a Codex guardian rollout is called on a card.
    public static let autoReview = "auto review"

    /// The chip for a session, or `nil` when its variant is not one a reader
    /// needs.
    public static func label(for identity: SessionIdentity) -> String? {
        if SessionRelations.isAutoReview(identity) { return autoReview }
        return label(forVariant: identity.variant)
    }

    /// The chip for a bare variant string, for the callers that hold one
    /// without an identity around it.
    ///
    /// Auto Review is not answered here: deciding that a variant is a Codex
    /// one needs the harness, which a bare string does not carry — see
    /// ``SessionRelations/autoReviewRootID(of:)``.
    public static func label(forVariant variant: String?) -> String? {
        switch variant {
        case AntigravityLiveAdapter.cliVariant: AntigravityLiveAdapter.cliVariant
        case AntigravityLiveAdapter.ideVariant: AntigravityLiveAdapter.ideVariant
        default: nil
        }
    }
}
