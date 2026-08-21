import AgentSessionLive
import Foundation

/// How much prose, and of what kind, Auspex has indexed for one session since
/// its last compaction.
///
/// Characters, not tokens. The conversion is a guess and belongs in one place
/// — ``ContextCompositionEstimator/charactersPerToken`` — rather than being
/// baked into a count that then reads like a measurement.
public struct ContextTextVolume: Hashable, Sendable {
    /// Characters of what a person typed.
    public let userCharacters: Int
    /// Characters of model prose.
    public let assistantCharacters: Int
    /// Characters of tool output.
    public let toolResultCharacters: Int
    /// How many stored bodies were counted.
    public let events: Int
    /// `true` when the scan hit its row cap and there is older text it did not
    /// read. The estimate is then a floor rather than an estimate, and the
    /// popover says so.
    public let isTruncated: Bool
    /// `true` when the scan started after a compaction rather than at the
    /// beginning of the session — which is what makes it an estimate of the
    /// *current* window rather than of everything ever said.
    public let sinceCompaction: Bool

    public init(
        userCharacters: Int = 0,
        assistantCharacters: Int = 0,
        toolResultCharacters: Int = 0,
        events: Int = 0,
        isTruncated: Bool = false,
        sinceCompaction: Bool = false
    ) {
        self.userCharacters = userCharacters
        self.assistantCharacters = assistantCharacters
        self.toolResultCharacters = toolResultCharacters
        self.events = events
        self.isTruncated = isTruncated
        self.sinceCompaction = sinceCompaction
    }

    /// Nothing indexed. What a session Auspex met after the fact answers.
    public static let empty = ContextTextVolume()

    public var isEmpty: Bool { events == 0 }
}

/// What is taking up a session's context window, as far as anything on this
/// machine can say.
///
/// ## Why this is an estimate and says so everywhere
///
/// Claude Code's `/context` panel is exact because Claude Code is the thing
/// holding the window: it knows the system prompt, the tool schemas, the
/// skills it loaded and the memory files it read. None of that is written to
/// disk. What *is* on disk is the conversation, which Auspex indexes anyway —
/// so the messages and the tool results can be estimated at four characters to
/// the token, and everything else has to be inferred as the remainder.
///
/// That remainder is the honest shape of the answer, and it is why there are
/// four slices rather than Claude's seven. Auspex can measure two of them and
/// subtract for the third; inventing "System tools 1.9 %" from a number nobody
/// wrote down would be a worse answer than a bar that says "everything else".
///
/// ## Why the measured slices are scaled to fit
///
/// Four characters to the token is wrong in both directions — code and JSON
/// run denser, prose runs thinner — so the estimated halves can add up to more
/// than the window actually holds. When they do, both are scaled down in
/// proportion rather than one being clipped: the ratio between messages and
/// tool output is the part of this that is worth reading, and it survives the
/// scaling. ``isOverEstimated`` records that it happened.
public struct ContextComposition: Hashable, Sendable {
    /// One band of the bar.
    public struct Slice: Hashable, Sendable, Identifiable {
        public enum Kind: String, Sendable, Hashable, CaseIterable {
            /// Prompts and model prose.
            case messages
            /// What tools returned.
            case toolResults
            /// The system prompt, the tool schemas, skills, MCP definitions,
            /// memory files — everything the harness put in the window and
            /// never wrote down. Inferred by subtraction, never measured.
            case everythingElse
            /// Room left.
            case free
        }

        public let kind: Kind
        /// Estimated tokens in this band.
        public let tokens: Int
        /// The band as a fraction of the whole window, `0...1`.
        public let fraction: Double

        public var id: String { kind.rawValue }

        public var title: String {
            switch kind {
            case .messages: "Messages"
            case .toolResults: "Tool results"
            case .everythingElse: "Everything else"
            case .free: "Free"
            }
        }

        /// Whether this band was counted or inferred. Drawn differently,
        /// because "we measured this" and "this is what was left over" are
        /// different claims.
        public var isMeasured: Bool {
            kind == .messages || kind == .toolResults
        }

        public init(kind: Kind, tokens: Int, fraction: Double) {
            self.kind = kind
            self.tokens = tokens
            self.fraction = fraction
        }
    }

    /// The bands, in the order they are drawn: measured first, then the
    /// remainder, then the room left.
    public let slices: [Slice]
    /// The window the fractions are of.
    public let window: Int
    /// The fill the bands add up to.
    public let used: Int
    /// How many stored bodies the estimate was built from.
    public let sampledEvents: Int
    /// The scan hit its cap; there is older text it did not read.
    public let isTruncated: Bool
    /// The scan began after a compaction, so it describes the current window
    /// rather than the whole session.
    public let sinceCompaction: Bool
    /// The measured bands added up to more than the window held and were
    /// scaled to fit. See the type's discussion.
    public let isOverEstimated: Bool

    public init(
        slices: [Slice],
        window: Int,
        used: Int,
        sampledEvents: Int,
        isTruncated: Bool,
        sinceCompaction: Bool,
        isOverEstimated: Bool
    ) {
        self.slices = slices
        self.window = window
        self.used = used
        self.sampledEvents = sampledEvents
        self.isTruncated = isTruncated
        self.sinceCompaction = sinceCompaction
        self.isOverEstimated = isOverEstimated
    }

    /// The band for one kind, when there is one.
    public func slice(_ kind: Slice.Kind) -> Slice? {
        slices.first { $0.kind == kind }
    }

    /// `true` when almost none of the fill could be attributed to indexed
    /// text, so ``Slice/Kind/everythingElse`` is standing in for "we did not
    /// see this" rather than for "the harness put this here".
    ///
    /// The shape a session Auspex met after it started has, and the shape a
    /// harness that logs no tool output has. Without a flag the panel would
    /// present a 96k remainder as a claim about a system prompt.
    public var isMostlyUnattributed: Bool {
        guard used > 0 else { return false }
        let measured = (slice(.messages)?.tokens ?? 0) + (slice(.toolResults)?.tokens ?? 0)
        return Double(measured) / Double(used) < 0.1
    }
}

/// Turns indexed characters and a measured fill into a composition.
///
/// Pure and total: no store, no clock, no throw. The I/O half is
/// `SessionRepository.contextTextVolume(key:limit:)`, which is what makes the
/// arithmetic here testable without a database.
public enum ContextCompositionEstimator {
    /// Characters per token.
    ///
    /// Four is the number every vendor's rule of thumb lands on for English
    /// prose, and it is wrong for the two things a coding session is mostly
    /// made of — source, which is denser, and JSON tool output, which is
    /// denser still. It is used anyway because the alternative is a tokenizer
    /// per model in a process whose whole budget is three per cent of one CPU,
    /// for a panel that already says "estimate" on it.
    public static let charactersPerToken = 4.0

    /// The composition of a window, or `nil` when there is nothing to say.
    ///
    /// `nil` when the gauge has no window — a bar of fractions needs a
    /// denominator — or when nothing has been indexed, because a bar that is
    /// entirely "everything else" tells a reader less than no bar does.
    public static func estimate(
        volume: ContextTextVolume,
        gauge: ContextGauge
    ) -> ContextComposition? {
        guard let window = gauge.window, window > 0, !volume.isEmpty else { return nil }
        let used = max(0, gauge.used)

        var messages = tokens(volume.userCharacters + volume.assistantCharacters)
        var toolResults = tokens(volume.toolResultCharacters)

        // Scaled rather than clipped: the ratio between the two is the part of
        // this worth reading, and clipping one of them would destroy it.
        let measured = messages + toolResults
        let isOverEstimated = measured > used
        if isOverEstimated, measured > 0 {
            let scale = Double(used) / Double(measured)
            messages = Int((Double(messages) * scale).rounded())
            toolResults = max(0, used - messages)
        }

        let everythingElse = max(0, used - messages - toolResults)
        let free = max(0, window - used)

        let slices = [
            ContextComposition.Slice(
                kind: .messages, tokens: messages, fraction: fraction(messages, of: window)
            ),
            ContextComposition.Slice(
                kind: .toolResults, tokens: toolResults, fraction: fraction(toolResults, of: window)
            ),
            ContextComposition.Slice(
                kind: .everythingElse,
                tokens: everythingElse,
                fraction: fraction(everythingElse, of: window)
            ),
            ContextComposition.Slice(
                kind: .free, tokens: free, fraction: fraction(free, of: window)
            )
        ]

        return ContextComposition(
            slices: slices,
            window: window,
            used: used,
            sampledEvents: volume.events,
            isTruncated: volume.isTruncated,
            sinceCompaction: volume.sinceCompaction,
            isOverEstimated: isOverEstimated
        )
    }

    private static func tokens(_ characters: Int) -> Int {
        characters <= 0 ? 0 : Int((Double(characters) / charactersPerToken).rounded())
    }

    private static func fraction(_ value: Int, of window: Int) -> Double {
        window > 0 ? min(max(Double(value) / Double(window), 0), 1) : 0
    }
}
