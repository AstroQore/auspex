import AgentSessionKit
import AgentSessionLive
import AppKit
import AuspexCore
import SwiftUI

/// The crew: one geometric avatar per session, grouped exactly as the board is.
///
/// A third way of reading the same ``BoardSnapshot``. The wall of cards answers
/// "what is this session doing" precisely and the office answers "what is the
/// whole machine doing" pre-attentively; the crew sits between them. Every
/// session is one shape whose **whole body** morphs, so a state change is
/// legible from across a room without reading a word — which is what a colour
/// swatch and a pill cannot do at that distance.
///
/// It shares ``LiveBoardModel/selectedKey`` with the board and the office, so
/// clicking an avatar fills the trace inspector exactly as clicking a card
/// does.
struct CrewView: View {
    let model: LiveBoardModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The engines, one per session. A plain reference type rather than an
    /// `@Observable` one on purpose: the grid is already redrawn by the
    /// timeline, and an observable roster mutated while building that frame
    /// would invalidate the view that is mid-build.
    @State private var roster = CrewRoster()
    /// Whether any part of the window is on screen. A wall nobody can see
    /// should not be costing frames.
    @State private var isOnScreen = true

    /// 30 frames a second, not 60.
    ///
    /// The fastest thing an avatar does is a blink, and a blink lasts 0.18 s —
    /// five frames at this rate, enough to read as a blink and not as a jump.
    /// Everything else (gaze drift, the morphs, the orbit) is slower still. The
    /// second thirty frames would double the cost of a sixty-avatar wall and
    /// buy motion nobody can see.
    private static let frameInterval = 1.0 / 30.0

    /// A card is 200 points wide in the design, and the avatar inside it is
    /// 120. Below about 170 the avatar stops being readable at a glance, which
    /// is the whole point of this view, so the grid stops shrinking there and
    /// drops a column instead.
    private let columns = [
        GridItem(.adaptive(minimum: 172, maximum: 216), spacing: 16, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let name = model.projectFilterName {
                ProjectFilterBar(name: name, path: model.projectFilter ?? "") {
                    model.projectFilter = nil
                }
            }
            if model.groups.isEmpty {
                BoardEmptyState(model: model)
            } else {
                clocked
            }
        }
        .background(BoardSurfaceBackground())
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeOcclusionStateNotification
            )
        ) { _ in
            isOnScreen = NSApp?.occlusionState.contains(.visible) ?? true
        }
        // Sessions come and go; their engines should not outlive them. Keyed on
        // the count rather than on the keys themselves because comparing a few
        // hundred keys is not worth doing to reclaim a handful of structs — a
        // replacement that kept the count identical simply waits for the next
        // one.
        .onChange(of: model.board.sessions.count) {
            roster.prune(keeping: Set(model.board.sessions.map(\.key)))
        }
    }

    /// One clock for the whole wall.
    ///
    /// Every avatar samples the same instant, which is what keeps a morph that
    /// starts on two sessions at once from drifting apart. What is *not* shared
    /// is the phase: each avatar is offset by a fixed fraction of a second
    /// derived from its session id, so a wall of sixty does not blink in
    /// unison — which reads as a glitch rather than as life.
    private var clocked: some View {
        TimelineView(
            .animation(minimumInterval: Self.frameInterval, paused: !isOnScreen || reduceMotion)
        ) { context in
            grid(at: roster.seconds(since: context.date))
        }
    }

    private func grid(at now: TimeInterval) -> some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(model.groups) { group in
                    Section {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(group.sessions, id: \.key) { session in
                                card(for: session, at: now)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 20)
                    } header: {
                        BoardSectionHeader(group: group)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func card(for session: SessionSnapshot, at now: TimeInterval) -> some View {
        // Sampling happens here, inside the lazy grid's builder, so a session
        // scrolled off the wall costs nothing at all.
        CrewCard(
            session: session,
            frame: roster.frame(for: session, at: now, frozen: reduceMotion),
            isSelected: model.selectedKey == session.key,
            descendantCount: model.descendantCount(of: session.key)
        )
        .onTapGesture { model.selectedKey = session.key }
        .accessibilityAddTraits(.isButton)
    }
}

/// One session's card: the avatar, who it is, what it is doing, and what it
/// last said.
///
/// Internal rather than private because the offscreen renderer draws the same
/// card — a screenshot of a second, simpler drawing of the same thing would
/// prove nothing about this one.
///
/// The chrome is deliberately thin. The avatar is the content here — a card
/// that repeated in text everything the body is already showing would be a
/// board card drawn twice.
struct CrewCard: View {
    let session: SessionSnapshot
    let frame: BloubFrame
    let isSelected: Bool
    let descendantCount: Int

    private var isOver: Bool { session.state.isEnded }

    var body: some View {
        let style = session.state.style
        return VStack(spacing: 12) {
            CrewAvatarView(
                frame: frame,
                ink: session.key.harness.style.accent,
                paper: AuspexPalette.panel,
                glow: style.isAlarming ? style.color : nil
            )
            .frame(width: 120, height: 120)
            .overlay(alignment: .bottomTrailing) { childrenBadge }

            chrome
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 10)
        .padding(.vertical, 16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(AuspexPalette.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(
                    isSelected ? session.key.harness.style.accent.opacity(0.75)
                        : AuspexPalette.hairline,
                    lineWidth: isSelected ? 1.5 : 1
                )
        )
        .opacity(isOver ? 0.6 : 1)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.key.harness.displayName), \(title), \(session.state.label)"
        )
    }

    /// Everything that is not the avatar, held apart so the timeline's thirty
    /// ticks a second do not re-evaluate a stack of text that changes once a
    /// minute.
    private var chrome: some View {
        CrewCardChrome(
            harness: session.key.harness,
            title: title,
            state: session.state,
            isStale: session.isStale,
            said: said,
            isOver: isOver
        )
        .equatable()
    }

    /// The delegation count, as a corner badge.
    ///
    /// The children are already on the wall as their own avatars, so this says
    /// how many rather than which — thirteen chips would be a card nobody can
    /// read, and it is the same call the board card makes.
    @ViewBuilder
    private var childrenBadge: some View {
        if descendantCount > 0 {
            HStack(spacing: 2) {
                Image(systemName: "arrow.turn.down.right")
                    .font(.system(size: 7, weight: .bold))
                Text("\(descendantCount)")
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
            }
            .foregroundStyle(AuspexPalette.stateDelegating)
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                Capsule().fill(AuspexPalette.canvas.opacity(0.9))
            )
            .overlay(
                Capsule().strokeBorder(AuspexPalette.stateDelegating.opacity(0.45), lineWidth: 1)
            )
            .accessibilityLabel("\(descendantCount) sessions below this one")
        }
    }

    private var title: String {
        if let headline = session.identity.title, !headline.isEmpty { return headline }
        return String(session.key.sessionID.prefix(10))
    }

    /// The one line of words on the card: what the session is doing, in the
    /// harness's own vocabulary.
    private var said: String? {
        if let activity = session.state.activityDescription { return activity }
        if case .ended(let reason) = session.state { return Self.word(for: reason) }
        return session.identity.model
    }

    /// How a session finished, in one word.
    ///
    /// The reason and not the model: a card that has stopped moving is asking
    /// "did this finish or did it die", and the model is on the board card and
    /// in the trace header for whoever wants it.
    private static func word(for reason: SessionEndReason) -> String {
        switch reason {
        case .exited: "exited"
        case .killed: "killed"
        case .processGone: "process gone"
        case .unknown: "went quiet"
        }
    }
}

/// The static half of a card.
private struct CrewCardChrome: View, @MainActor Equatable {
    let harness: Harness
    let title: String
    let state: SessionState
    let isStale: Bool
    let said: String?
    let isOver: Bool

    static func == (lhs: CrewCardChrome, rhs: CrewCardChrome) -> Bool {
        lhs.harness == rhs.harness && lhs.title == rhs.title && lhs.state == rhs.state
            && lhs.isStale == rhs.isStale && lhs.said == rhs.said && lhs.isOver == rhs.isOver
    }

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 6) {
                HarnessBadge(harness: harness, size: 16, isMuted: isOver)
                Text(title)
                    .font(.system(size: 12.5, weight: .semibold))
                    .foregroundStyle(
                        isOver ? AuspexPalette.textTertiary : AuspexPalette.textPrimary
                    )
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity)

            StatePill(state: state, isStale: isStale)

            if let said {
                Text(said)
                    .font(.system(size: 11))
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(PathDisplay.truncation(for: said))
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// The avatars' engines, and the one clock they all read.
///
/// Kept out of the view because a ``CrewAvatarDriver`` has to survive across
/// frames — it is what remembers when a state changed, so the morph out of the
/// old pose is continuous — and because a session scrolled off the wall should
/// keep its place in the animation rather than restart when it comes back.
@MainActor
final class CrewRoster {
    private var drivers: [SessionKey: CrewAvatarDriver] = [:]
    /// The instant the wall started, so the clock is a small number of seconds
    /// rather than the seconds since 2001 — the engine's noise periods are a
    /// few seconds long, and a `Double` that large loses the resolution they
    /// need.
    private var epoch: Date?

    func seconds(since date: Date) -> TimeInterval {
        guard let epoch else {
            epoch = date
            return 0
        }
        return date.timeIntervalSince(epoch)
    }

    /// One session's frame at `now`.
    ///
    /// - Parameter frozen: with Reduce Motion on, the avatar holds the pose its
    ///   state reads most clearly at — the same instant bloub's own state board
    ///   uses. The shape still says what the session is doing; it just stops
    ///   drifting, blinking and orbiting, which is the request.
    func frame(for session: SessionSnapshot, at now: TimeInterval, frozen: Bool) -> BloubFrame {
        let key = session.key
        // A fixed offset per session, so sixty avatars do not blink in unison.
        // Derived from the session id rather than from an index, because an
        // index changes when the board re-sorts and the avatar would jump.
        let phase = Self.phase(of: key.sessionID)
        let clock = now + phase

        var driver = drivers[key] ?? CrewAvatarDriver(
            harness: key.harness,
            state: session.state,
            isStale: session.isStale,
            at: clock
        )
        driver.update(state: session.state, isStale: session.isStale, at: clock)
        drivers[key] = driver

        guard frozen else { return driver.sample(clock) }
        // A still engine placed on the state, sampled at its most legible
        // instant. Building it here rather than freezing the live one keeps the
        // live one's history intact for when Reduce Motion is turned back off.
        let mood = driver.mood
        let still = BloubEngine(state: mood.state, shape: mood.shape, expression: mood.expression)
        return still.sample(BloubStates.poseTime[mood.state] ?? 1)
    }

    /// Forgets the sessions the board no longer has.
    func prune(keeping keys: Set<SessionKey>) {
        drivers = drivers.filter { keys.contains($0.key) }
    }

    /// A stable offset in [0, 3.7) seconds — a little more than the longest gap
    /// between two scheduled blinks, so the whole schedule is spread out.
    ///
    /// FNV-1a rather than `hashValue`: Swift seeds its hasher per process, and
    /// a phase that changed on every launch would be a wall that blinks
    /// differently every morning for no reason.
    private static func phase(of id: String) -> TimeInterval {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return Double(hash % 3_700) / 1_000
    }
}
