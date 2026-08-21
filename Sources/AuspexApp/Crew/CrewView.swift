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
    /// How often the avatars react. Read from `settings.json` through the
    /// catalog, so the pane and the wall cannot disagree.
    var liveliness: CrewLiveliness = .default

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// The engines, one per session. A plain reference type rather than an
    /// `@Observable` one on purpose: the grid is already redrawn by the
    /// timeline, and an observable roster mutated while building that frame
    /// would invalidate the view that is mid-build.
    @State private var roster = CrewRoster()
    /// Whether any part of the window is on screen. A wall nobody can see
    /// should not be costing frames.
    @State private var isOnScreen = true
    /// A coarse clock, for the two things on a card that are about *elapsed*
    /// time rather than about animation: whether a finished turn is still worth
    /// a tick, and whether an ended session has been on the wall long enough to
    /// fold away.
    ///
    /// Five seconds, and only while something is actually waiting on it. Both
    /// windows are twenty seconds and a minute, so five is finer than either
    /// needs — and when nothing is pending the loop stops entirely rather than
    /// re-laying out a wall of sixty cards for no reason.
    @State private var now = Date()

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
        .onChange(of: liveliness, initial: true) { roster.liveliness = liveliness }
        .task(id: model.sessionCount) {
            // Runs only while a card is counting down to something. A wall of
            // settled sessions leaves this loop immediately and costs nothing.
            while !Task.isCancelled, needsClock {
                try? await Task.sleep(for: .seconds(5))
                if Task.isCancelled { return }
                now = Date()
            }
        }
    }

    /// Whether anything on the wall is waiting on the coarse clock.
    private var needsClock: Bool {
        model.board.sessions.contains { session in
            if session.state.isEnded { return !CrewView.hasFolded(session, at: now) }
            return CrewCardChrome.of(session, at: now) == .done
        }
    }

    /// Whether a finished session has been on the wall long enough to fold.
    ///
    /// A minute. Long enough that somebody who was watching sees it fall asleep
    /// where it was working — which is the whole point of drawing an ended
    /// session at all — and short enough that a machine which has run two
    /// hundred sessions today is not a wall of grey.
    static func hasFolded(_ session: SessionSnapshot, at now: Date) -> Bool {
        guard session.state.isEnded else { return false }
        guard let endedAt = session.endedAt else { return true }
        return now.timeIntervalSince(endedAt) > CrewMoodMap.endedFold
    }

    private var grid: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(model.groups) { group in
                    let awake = group.sessions.filter { !CrewView.hasFolded($0, at: now) }
                    let folded = group.sessions.filter { CrewView.hasFolded($0, at: now) }
                    Section {
                        LazyVGrid(columns: columns, spacing: 16) {
                            ForEach(awake, id: \.key) { session in
                                card(for: session)
                                    .transition(Self.cardTransition)
                            }
                        }
                        .padding(.horizontal, 20)
                        .padding(.top, 14)
                        .padding(.bottom, folded.isEmpty ? 20 : 4)
                        // The ids are the session keys and they are stable, so
                        // a card that moves to another slot when the board
                        // re-sorts is the *same* view and SwiftUI glides it
                        // there. All this adds is the curve it glides on — and
                        // the arrivals and departures above ride the same one.
                        .animation(
                            .spring(duration: 0.5, bounce: 0.15),
                            value: awake.map(\.key)
                        )

                        if !folded.isEmpty {
                            CrewEndedFold(sessions: folded, selected: model.selectedKey) {
                                model.selectedKey = $0
                            }
                            .padding(.horizontal, 20)
                            .padding(.bottom, 20)
                            .transition(.opacity)
                            .animation(.easeInOut(duration: 0.4), value: folded.count)
                        }
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
            descendantCount: model.descendantCount(of: session.key),
            chrome: CrewCardChrome.of(session, at: now)
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
    let frame: BloubFrame
    /// The eased pop the driver plays on a change of stance. 1 when at rest.
    var pop: Double = 1
    /// Whether the session is over.
    ///
    /// An ended avatar is **asleep and grey**: eyes shut, the harness accent
    /// mixed most of the way to the page's own grey, and the whole body at
    /// 55 %. That is the entire idle-versus-ended distinction, and it is worth
    /// spending colour on: idle is awake — open eyes, blinks, a drifting gaze,
    /// the occasional reaction, full accent — and ended is none of those. A
    /// wall where the two look alike is a wall you have to read the pills on.
    var isOver: Bool = false

    var body: some View {
        CrewAvatarView(
            frame: frame,
            // No halo here any more. A session that needs you says so in the
            // card's own chrome — a ring and a badge, where the eye already
            // goes for status — because the body's job is to say which harness
            // this is, and a shape wearing a red glow stops saying it.
            ink: isOver
                ? harness.style.accent.mix(with: AuspexPalette.textTertiary, by: 0.72)
                : harness.style.accent,
            paper: AuspexPalette.panel
        )
        .opacity(isOver ? 0.55 : 1)
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
                frame: instant.frame,
                pop: instant.pop,
                isOver: instant.stance == .ended
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
    /// What the card says over and above the avatar. Defaults to nothing, so
    /// a caller that has no clock — the still renderer — gets a plain card.
    var chrome: CrewCardChrome = .none
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

    private var isOver: Bool { chrome == .over || session.state.isEnded }

    var body: some View {
        VStack(spacing: 12) {
            avatar
                .frame(width: 120, height: 120)
                .overlay(alignment: .bottomTrailing) { childrenBadge }

            text
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
        // The attention ring, and the reason it is here rather than around the
        // avatar. A halo on the body competes with the body's own job — saying
        // which harness this is — and on a wall of twelve it reads as a
        // different *kind* of avatar rather than as a different state. On the
        // card it reads as what it is: this row of the board wants you.
        .overlay {
            if let alarm = chrome.ringColour {
                CrewAttentionRing(colour: alarm)
            }
        }
        .overlay(alignment: .topTrailing) { statusBadge }
        .opacity(isOver ? 0.6 : 1)
        .animation(.easeInOut(duration: 0.4), value: isOver)
        .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "\(session.key.harness.displayName), \(title), \(session.state.label)"
        )
    }

    /// The corner mark: a "!" for a session that wants you, a tick for one
    /// whose turn finished while you were elsewhere.
    ///
    /// Small, and deliberately in the corner rather than on the body. The
    /// avatar is already saying what the session is doing with its eyes; the
    /// badge says whether *you* have something to do, which is a different
    /// question and belongs where a person scans for answers to it.
    @ViewBuilder
    private var statusBadge: some View {
        if let badge = chrome.badge {
            Image(systemName: badge.symbol)
                .font(.system(size: 9, weight: .heavy))
                .foregroundStyle(AuspexPalette.canvas)
                .frame(width: 16, height: 16)
                .background(Circle().fill(badge.colour))
                .overlay(Circle().strokeBorder(AuspexPalette.canvas.opacity(0.6), lineWidth: 1))
                .padding(7)
                .accessibilityLabel(badge.label)
                .transition(.scale.combined(with: .opacity))
        }
    }

    /// Everything that is not the avatar, held apart so the timeline's thirty
    /// ticks a second do not re-evaluate a stack of text that changes once a
    /// minute.
    private var text: some View {
        CrewCardText(
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

/// The sessions that have finished and have been finished long enough.
///
/// A card is a claim on attention, and a session that ended two minutes ago has
/// none left to make: it is history, and history belongs in a line rather than
/// in a grid. So it folds down to a dot in the harness's own colour, muted the
/// way the sleeping avatar is muted, and clicking one still fills the trace
/// inspector — nothing is lost, it just stops shouting.
private struct CrewEndedFold: View {
    let sessions: [SessionSnapshot]
    let selected: SessionKey?
    let onSelect: (SessionKey) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            Image(systemName: "moon.zzz")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(AuspexPalette.textTertiary)
            Text("\(sessions.count) asleep")
                .auspexLabel(AuspexType.label)
                .foregroundStyle(AuspexPalette.textTertiary)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                ForEach(sessions, id: \.key) { session in
                    dot(for: session)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AuspexPalette.panel.opacity(0.5))
        )
    }

    private func dot(for session: SessionSnapshot) -> some View {
        Circle()
            .fill(
                session.key.harness.style.accent
                    .mix(with: AuspexPalette.textTertiary, by: 0.72)
                    .opacity(0.55)
            )
            .frame(width: 10, height: 10)
            .overlay {
                if selected == session.key {
                    Circle().strokeBorder(session.key.harness.style.accent, lineWidth: 1.5)
                        .frame(width: 14, height: 14)
                }
            }
            .frame(width: 14, height: 14)
            .contentShape(Circle())
            .onTapGesture { onSelect(session.key) }
            .help("\(session.key.harness.displayName) — finished")
            .accessibilityLabel("\(session.key.harness.displayName), finished")
    }
}

/// What the card itself says about a session, over and above the avatar.
///
/// The crew's state language is the face, and the face is a mood rather than a
/// demand. Two things on a board are demands — a session waiting on a person,
/// and a turn that finished while nobody was looking — and both of them need to
/// be findable from across a room without decoding an expression. So they are
/// card chrome: a breathing ring and a corner badge, in the board's own state
/// colours, exactly where the board already puts status.
enum CrewCardChrome: Sendable, Hashable {
    case none
    /// Waiting on you. It will not resolve itself.
    case blocked
    /// A turn finished and nobody has looked yet.
    case done
    /// Over.
    case over

    /// The colour of the breathing ring, or `nil` for no ring.
    var ringColour: Color? {
        switch self {
        case .blocked: AuspexPalette.statePermission
        case .done: AuspexPalette.stateWriting
        case .none, .over: nil
        }
    }

    var badge: (symbol: String, colour: Color, label: String)? {
        switch self {
        case .blocked: ("exclamationmark", AuspexPalette.statePermission, "waiting for you")
        case .done: ("checkmark", AuspexPalette.stateWriting, "finished")
        case .none, .over: nil
        }
    }

    /// What a session's card is saying at `now`.
    ///
    /// Derived from the snapshot rather than read out of the avatar's driver,
    /// so a renderer with no roster gets the same answer as the live wall.
    static func of(_ session: SessionSnapshot, at now: Date) -> CrewCardChrome {
        if session.state.isEnded { return .over }
        if case .waitingPermission = session.state { return .blocked }
        if case .idle = session.state, session.turnCount > 0,
           let last = session.lastEventAt,
           now.timeIntervalSince(last) < CrewMoodMap.notifyHold {
            return .done
        }
        return .none
    }
}

/// The ring that says a card wants you.
///
/// Its own clock, and a slow one: a 2.4-second breath cannot use more than a
/// dozen frames a second, and only the cards that are actually shouting pay for
/// it. A static ring is a sticker; a breathing one is a thing waiting for you.
///
/// ## The shadow's radius is constant, and that is not a detail
///
/// It breathed at first — `radius: 7 + 5 * breath` — and the wall went from
/// 14 % of a core to **100 %**, pinned, with the main thread spinning in
/// `LazySubviewPlacements.placeSubviews`. A shadow enlarges the view's drawing
/// bounds, so a radius that changes is a *layout* change, and a layout change
/// inside a `LazyVGrid` re-places every subview the lazy container is
/// tracking — fourteen cards, twelve times a second, cascading through the
/// enclosing `LazyVStack`. Measured A/B against `main`, which sat at 1–14 %.
///
/// Breathing the *colour* costs a redraw of one overlay and nothing else.
/// The rule that follows: inside a lazy container, animate what is painted,
/// never what is measured.
private struct CrewAttentionRing: View {
    let colour: Color

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 12, paused: false)) { context in
            let breath = 0.5 - 0.5 * cos(
                context.date.timeIntervalSinceReferenceDate * (bloubTau / 2.4)
            )
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(colour.opacity(0.45 + 0.4 * breath), lineWidth: 1.5)
                .shadow(color: colour.opacity(0.14 + 0.20 * breath), radius: 9)
        }
        .allowsHitTesting(false)
    }
}

/// The static half of a card.
private struct CrewCardText: View, @MainActor Equatable {
    let harness: Harness
    let title: String
    let state: SessionState
    let isStale: Bool
    let said: String?
    let isOver: Bool

    static func == (lhs: CrewCardText, rhs: CrewCardText) -> Bool {
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
    /// What the face is doing — the crew's whole state language.
    var stance: CrewStance
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
    /// How often the avatars react. Handed to each driver on the next frame
    /// rather than pushed: a reaction already in flight finishes, because the
    /// setting is about the *next* one.
    var liveliness: CrewLiveliness = .default
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
            seed: UInt32(truncatingIfNeeded: Self.hash(of: key.sessionID) >> 32),
            liveliness: liveliness
        )
        driver.setLiveliness(liveliness)
        driver.update(state: session.state, isStale: session.isStale, at: clock)
        drivers[key] = driver

        guard frozen else {
            return CrewInstant(
                frame: driver.sample(clock),
                pop: driver.pop(at: clock),
                stance: driver.mood.stance,
                interval: driver.frameInterval(at: clock)
            )
        }
        // A still body wearing the stance's own first face. Building it here
        // rather than freezing the live one keeps the live one's history intact
        // for when Reduce Motion is turned back off.
        //
        // The face is read off a *fresh* choreographer at its own start, so it
        // is the pose the stance opens on rather than whichever step of the
        // loop the clock happened to stop in. The shape still says which
        // harness this is and the eyes still say what it is doing; all that
        // stops is the drifting, the blinking and the reactions, which is the
        // request.
        let mood = driver.mood
        var still = BloubEngine(state: .idle, shape: mood.shape, expression: .neutral)
        still.reset(to: .idle, at: 0)
        let pose = CrewChoreographer(seed: 0, stance: mood.stance, at: 0).sample(at: 0)
        return CrewInstant(
            frame: still.sample(1, face: BloubFaceOverride(expression: pose.face, lid: pose.lid)),
            pop: 1,
            stance: mood.stance,
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
