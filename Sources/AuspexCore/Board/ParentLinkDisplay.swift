import AgentSessionLive
import Foundation

extension ParentLink {
    /// How the link was established, in one word a reader can act on.
    ///
    /// The kind of evidence is not a detail. "The parent's own log recorded
    /// this spawn" and "these two processes share an ancestor" are different
    /// claims, and only one of them can be wrong in a way that moves a card
    /// under a repository it has nothing to do with. A trace header that shows
    /// a parent without saying how it was worked out invites a reader to trust
    /// a guess as much as a record.
    public var evidenceLabel: String {
        switch self {
        case .subagent: "Subagent"
        case .envInherited: "Environment"
        case .spawnedProcess: "Process tree"
        case .manual: "Linked by you"
        }
    }

    /// The same thing as a sentence, for a tooltip.
    public var evidenceDescription: String {
        switch self {
        case .subagent:
            "The parent's own transcript recorded spawning this session."
        case .envInherited:
            "The parent's session id was in this process's environment, which "
                + "only the parent could have put there."
        case .spawnedProcess:
            "This process descends from the parent's. A shared shell can "
                + "produce the same relationship, so this is the weakest link "
                + "Auspex draws."
        case .manual:
            "You linked these two sessions. Auspex never overwrites that."
        }
    }
}
