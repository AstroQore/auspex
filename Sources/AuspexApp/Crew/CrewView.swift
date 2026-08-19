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

    // The wall has no single frame rate any more, and that is the point.
    //
    // It began at 30 everywhere, on the argument that a blink lasts 0.18 s and
    // would still get five frames. That answered whether a motion is *legible*
    // when the complaint was that it was not *smooth* — a 480 ms morph at 30
    // fps is fourteen steps, enough to see and enough to see the steps. Putting
    // the whole wall at 60 fixed the motion and cost four times the budget.
    //
    // So the rate follows the card: 60 while something is in flight and for the
    // orbit's fast rings, 30 for the slower continuous states, 15 for a still
    // pose that is only drifting, nothing at all for a session that has ended.
    // ``CrewCadence`` holds the tiers and ``CrewAvatarDriver/frameInterval(at:)``
    // the rule. Every card still stops dead the moment the window is hidden.

    /// How a card arrives and how it leaves.
    ///
    /// Asymmetric on purpose: a new session should feel like it walked in, so
    /// it grows the visible 10 %; a card going away should not draw attention
    /// to itself on the way out, so it barely moves.
    private static let cardTransition = AnyTransition.asymmetric(
        insertion: .scale(scale: 0.9).combined(with: .opacity),
        removal: .scale(scale: 0.96).combined(with: .opacity)
    )

    /// A card is 200 points wide in the design, and the avatar inside it is
    /// 120. Below about 170 the avatar stops being readable at a glance, which
    /// is the whole point of this view, so the grid stops shrinking there and
    /// drops a column instead.
    private let columns = [
        GridItem(.adaptive(minimum: 172, maximum: 216), spacing: 16, alignment: .top)
    ]

    var body: some View {
        VStack(spacing: 0) {
            if let name = model.focusedProjectName {
                ProjectFilterBar(name: name, path: model.focusedProjectKey ?? "") {
                    model.focusedProjectKey = nil
                }
            }
            if model.groups.isEmpty {
                BoardEmptyState(model: model)
            } else {
                grid
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
        // The count comes off the model's own derived property rather than out
        // of the frame: `board` is replaced on every applied frame, so reading
        // it here would subscribe this body to all of them.
        .onChange(of: model.sessionCount) {
            roster.prune(keeping: Set(model.board.sessions.map(\.key)))
        }
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(model.groups) { group in
                    Section {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(group.sessions, id: \.key) { session in
                                card(for: session)
                                    .transition(Self.cardTransition)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, 20)
                        // The ids are the session keys and they are stable, so
                        // a card that moves to another slot when the board
                        // re-sorts is the *same* view and SwiftUI glides it
                        // there. All this adds is the curve it glides on — and
                        // the arrivals and departures above ride the same one.
                        .animation(
                            .spring(duration: 0.5, bounce: 0.15),
                            value: group.sessions.map(\.key)
                        )
                    } header: {
                        BoardSectionHeader(group: group)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private func card(for session: SessionSnapshot) -> some View {
        // Built inside the lazy grid's builder, so a session scrolled off the
        // wall costs nothing at all — and clocked one level further down, so a
        // frame costs a Canvas and not a grid.
        CrewCard(
            session: session,
            isSelected: model.selectedKey == session.key,
            descendantCount: model.descendantCount(of: session.key)
        ) {
            CrewLiveAvatar(
                session: session,
                roster: roster,
                paused: !isOnScreen || reduceMotion,
                frozen: reduceMotion
            )
        }
        .onTapGesture { model.selectedKey = session.key }
        .accessibilityAddTraits(.isButton)
    }
}

/// One avatar, drawn at one instant. Everything the wall's clock feeds it.
///
/// Separate from ``CrewLiveAvatar`` because the offscreen renderers hand it a
/// frame they sampled themselves: the still and the filmstrip must go through
/// exactly the drawing the app uses, and neither of them has a clock.
struct CrewStillAvatar: View {
    let harness: Harness
    let state: SessionState
    let frame: BloubFrame
    /// The eased pop the driver plays on a state change. 1 when at rest.
    var pop: Double = 1
    /// How bright a needs-you halo is right now.
    var glowStrength: Double = 1

    var body: some View {
        let style = state.style
        return CrewAvatarView(
            frame: frame,
            ink: harness.style.accent,
            paper: AuspexPalette.panel,
            glow: style.isAlarming ? style.color : nil,
            glowStrength: glowStrength
        )
        .scaleEffect(pop)
    }
}

/// The same avatar, with the wall's clock behind it.
///
/// The clock sits here — around one `Canvas` — and not around the grid. Sixty
/// of these are still **one** clock in the sense the performance budget means:
/// `TimelineView(.animation)` schedules run off the display link, so they all
/// tick together on the same date, every avatar samples the same instant, and a
/// morph starting on two sessions at once cannot drift apart. What sixty
/// separate timelines buy is that a tick invalidates sixty `Canvas`es instead
/// of the whole wall's view list and layout. Measured, that is the difference
/// between the budget and four times it.
///
/// And once each card owns its schedule, the *rate* can follow what that card
/// is doing rather than what the busiest card on the wall is doing. The driver
/// answers with the interval (``CrewAvatarDriver/frameInterval(at:)``); this
/// view's only job is to notice when the answer changes and hand SwiftUI a new
/// schedule. The answer is read inside the timeline, where the clock already
/// is, and applied through `onChange`, which runs *after* the update rather
/// than during it.
struct CrewLiveAvatar: View {
    let session: SessionSnapshot
    let roster: CrewRoster
    let paused: Bool
    let frozen: Bool

    /// The interval currently asked of the display link. Starts at the full
    /// rate: a card that has just appeared is inside its own opening morph.
    @State private var interval: Double? = CrewCadence.full

    /// One breath for the whole wall, off the shared clock: cards that are
    /// waiting on you pulse together, the way a row of indicator lamps does.
    ///
    /// Held at a **constant** on every card that has no halo, rather than
    /// computed and then multiplied away. The halo is two `.shadow`s, and a
    /// shadow whose radius changes is one SwiftUI reconsiders every frame even
    /// when its colour is clear, so there is no reason to hand a moving number
    /// to the ten cards that are not shouting. On a machine loaded by other
    /// work the saving could not be separated from the noise; it is kept
    /// because it cannot cost anything and the intent is clearer. Reduce Motion
    /// holds the other two still as well.
    private func breath(at now: TimeInterval) -> Double {
        guard !frozen, session.state.style.isAlarming else { return 1 }
        return 0.5 - 0.5 * cos(now * (bloubTau / 2.4))
    }

    var body: some View {
        TimelineView(
            .animation(
                minimumInterval: interval ?? CrewCadence.low,
                paused: paused || interval == nil
            )
        ) { context in
            let now = roster.seconds(since: context.date)
            let instant = roster.instant(for: session, at: now, frozen: frozen)
            CrewStillAvatar(
                harness: session.key.harness,
                state: session.state,
                frame: instant.frame,
                pop: instant.pop,
                glowStrength: breath(at: now)
            )
            .onChange(of: instant.interval) { _, wanted in interval = wanted }
        }
        // A paused card has no clock left to notice anything with, so waking it
        // cannot come from inside the timeline. These two are the only ways an
        // avatar's state can change, and both arrive as a new snapshot from the
        // model — which updates this view whatever its schedule is doing.
        .onChange(of: session.state) { interval = CrewCadence.full }
        .onChange(of: session.isStale) { interval = CrewCadence.full }
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
struct CrewCard<Avatar: View>: View {
    let session: SessionSnapshot
    let isSelected: Bool
    let descendantCount: Int
    /// The moving half, handed in rather than built here.
    ///
    /// This is the seam that keeps a frame cheap. The card — its background,
    /// its border, its badge, its pill, its two lines of text — is a view list
    /// SwiftUI makes when the *board* changes, a few times a minute. Only what
    /// goes in this slot is rebuilt sixty times a second, and on the wall that
    /// is one `Canvas`. Build the avatar inside `body` instead and the clock
    /// invalidates the card, the grid row, the section and the layout with it,
    /// which is what a profile of the first version was almost entirely made
    /// of.
    @ViewBuilder var avatar: Avatar

    private var isOver: Bool { session.state.isEnded }

    var body: some View {
        VStack(spacing: 12) {
            avatar
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
                // The ring is the answer to a click, so it may not simply be
                // there on the next frame: it has to be seen arriving, or the
                // click reads as having selected nothing.
                .animation(.easeInOut(duration: 0.26), value: isSelected)
        )
        .opacity(isOver ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.4), value: isOver)
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

    /// What has to change for the pill to be swapped rather than redrawn: the
    /// words on it and the colour behind them. Not the child count, which the
    /// pill is not showing here.
    private var pillIdentity: String { "\(state.label)|\(isStale)" }

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

            // The count is off here: the card already draws it as a badge on
            // the avatar's corner, and the same number twice on one card reads
            // as two facts.
            //
            // The pill is replaced rather than mutated — a new `id` is a new
            // view — so the outgoing and the incoming one cross-fade through
            // each other with a 3 % pop. Re-colouring the same pill in place
            // gives a word that changes underneath a shape that did not, which
            // is the small snap this whole branch is about.
            ZStack {
                StatePill(state: state, isStale: isStale, showsChildCount: false)
                    .id(pillIdentity)
                    .transition(
                        .opacity.combined(with: .scale(scale: 1.03))
                    )
            }
            .animation(.spring(duration: 0.34, bounce: 0.2), value: pillIdentity)

            if let said {
                Text(said)
                    .font(.system(size: 11))
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(PathDisplay.truncation(for: said))
                    .frame(maxWidth: .infinity)
                    .id(said)
                    .transition(.opacity)
            }
        }
        .padding(.horizontal, 4)
        // The line under the pill changes far more often than the pill does —
        // every tool call — so it gets a crossfade and nothing else. Anything
        // with movement in it would make the card twitch all day.
        .animation(.easeInOut(duration: 0.3), value: said)
    }
}

/// One avatar's whole instant: the frame the engine drew and the scale the card
/// wears while its state is changing.
///
/// The pop travels with the frame rather than being derived in the view because
/// it is the *driver* that knows when the state changed — the frame alone
/// cannot say whether it is 20 ms or 2 s into the morph it belongs to.
struct CrewInstant {
    var frame: BloubFrame
    var pop: Double
    /// How long the wall may wait before drawing this avatar again, or `nil`
    /// when it need not draw it at all. See ``CrewAvatarDriver/frameInterval(at:)``.
    var interval: Double?
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

    /// One session's whole instant at `now`.
    ///
    /// - Parameter frozen: with Reduce Motion on, the avatar holds the pose its
    ///   state reads most clearly at — the same instant bloub's own state board
    ///   uses. The shape still says what the session is doing; it just stops
    ///   drifting, blinking and orbiting, which is the request.
    func instant(for session: SessionSnapshot, at now: TimeInterval, frozen: Bool) -> CrewInstant {
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
            at: clock,
            // The same hash the phase comes from, taken from the other end:
            // the phase spreads the blink schedule, the seed gives each avatar
            // its own resting gaze. Two avatars would otherwise still trace the
            // same drift, one merely a couple of seconds behind the other.
            seed: UInt32(truncatingIfNeeded: Self.hash(of: key.sessionID) >> 32)
        )
        driver.update(state: session.state, isStale: session.isStale, at: clock)
        drivers[key] = driver

        guard frozen else {
            return CrewInstant(
                frame: driver.sample(clock),
                pop: driver.pop(at: clock),
                interval: driver.frameInterval(at: clock)
            )
        }
        // A still engine placed on the state, sampled at its most legible
        // instant. Building it here rather than freezing the live one keeps the
        // live one's history intact for when Reduce Motion is turned back off.
        let mood = driver.mood
        let still = BloubEngine(state: mood.state, shape: mood.shape, expression: mood.expression)
        return CrewInstant(
            frame: still.sample(BloubStates.poseTime[mood.state] ?? 1),
            pop: 1,
            interval: nil
        )
    }

    /// Forgets the sessions the board no longer has.
    func prune(keeping keys: Set<SessionKey>) {
        drivers = drivers.filter { keys.contains($0.key) }
    }

    /// A stable offset in [0, 3.7) seconds — a little more than the longest gap
    /// between two scheduled blinks, so the whole schedule is spread out.
    private static func phase(of id: String) -> TimeInterval {
        Double(hash(of: id) % 3_700) / 1_000
    }

    /// FNV-1a rather than `hashValue`: Swift seeds its hasher per process, and
    /// a phase that changed on every launch would be a wall that blinks
    /// differently every morning for no reason.
    private static func hash(of id: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in id.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }
}
