import Foundation

/// Which release stream Auspex asks Sparkle to follow.
///
/// ## Two channels, not two feeds
///
/// There is one appcast at one URL, and every build reads it. What separates
/// the channels is a tag inside each item: Sparkle always considers items with
/// no `<sparkle:channel>` — that is the stable stream — and considers a tagged
/// item only when the running app has asked for that tag by name. So the
/// asymmetry is built into Sparkle rather than into us: stable users see
/// stable, dev users see dev *and* stable, and a security fix cut on the
/// stable channel reaches the preview builds without anything special being
/// done for them.
///
/// ## Why it is in `settings.json`
///
/// Same reason as ``AppearanceMode``: a person who chose the preview stream
/// and found themselves back on stable after a relaunch has been told their
/// setting did not take, and this is the setting where that mistake decides
/// which binary lands on their Mac. It is also a file people can read, which
/// matters for a preference whose whole job is "what am I allowed to be
/// upgraded to".
public enum UpdateChannel: String, Sendable, Codable, Hashable, CaseIterable, Identifiable {
    /// Sparkle's untagged default stream: released versions only.
    case main
    /// The `dev` stream — preview builds cut between releases — *plus* the
    /// default stream, which Sparkle always includes.
    case dev

    public var id: String { rawValue }

    /// What a fresh install gets, and what an unset key means.
    public static let standard = UpdateChannel.main

    /// What the picker's segment says.
    public var title: String {
        switch self {
        case .main: "Stable"
        case .dev: "Dev"
        }
    }

    /// One line under the picker, saying what the choice actually does.
    public var detail: String {
        switch self {
        case .main:
            "Released versions only. This is the one to be on."
        case .dev:
            "Preview builds cut between releases, plus every stable release. "
                + "They are built from a tag but they have not been lived with."
        }
    }

    /// The channel names handed back from `SPUUpdaterDelegate`.
    ///
    /// Empty means "the default stream only". It is never `["main"]`: no item
    /// in the feed is tagged `main`, so asking for that name by hand would
    /// match nothing and quietly stop stable users from updating at all.
    public var additionalSparkleChannels: Set<String> {
        switch self {
        case .main: []
        case .dev: ["dev"]
        }
    }
}
