import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// One session inside a piece of work, as the flock draws it.
///
/// A chick: the engine's own face on an egg, in the member's harness colour
/// held back to eight tenths of full so a row of them never competes with the
/// lead above it. See ``BloubShape/chick(_:rotation:centerX:centerY:)`` for
/// why the shape differs at all.
struct CrewChickAvatar: View {
    let harness: Harness
    let frame: BloubFrame
    var isOver: Bool = false

    /// How tall a chick is. Small enough that eight fit under a 150-point card
    /// in two rows, large enough that the eyes still read as eyes.
    static let size: CGFloat = 22

    var body: some View {
        CrewAvatarView(
            frame: Self.hatched(frame),
            ink: isOver
                ? harness.style.accent.mix(with: AuspexPalette.textTertiary, by: 0.72)
                : harness.style.accent.mix(with: AuspexPalette.panel, by: 0.2),
            paper: AuspexPalette.panel
        )
        .frame(width: Self.size, height: Self.size)
        .opacity(isOver ? 0.5 : 1)
    }

    /// The engine's frame with the body swapped for an egg.
    ///
    /// Only the body. The eyes, the blink and the drifting gaze are the same
    /// values the lead's face is drawn from — a chick that could not blink
    /// would be a sticker, and this wall's whole argument is that a still
    /// avatar tells you nothing a pill does not.
    static func hatched(_ frame: BloubFrame) -> BloubFrame {
        var hatched = frame
        hatched.body = BloubShape.closedOutline(
            BloubShape.points(BloubShape.chick(1), scale: frame.scale)
        )
        // The decorations belong to the lead's stances — a burst's particles
        // and the delegating orbit are motion a 22-point body cannot carry,
        // and at this size they read as dirt.
        hatched.dots = []
        hatched.arcs = []
        hatched.notify = nil
        hatched.notch = nil
        return hatched
    }
}

/// A chick with the wall's clock behind it.
///
/// ## Why this is its own view and its own rate
///
/// The same argument ``CrewLiveAvatar`` makes, one size down and with the
/// budget taken more seriously. A card can hold eight of these, so a wall of
/// forty cards could hold three hundred and twenty faces — at the lead's rate
/// that is the whole CPU budget spent on the things a person is *not* looking
/// at.
///
/// So a chick is pinned to the low tier — fifteen frames a second, whatever it
/// is doing — and it never asks for the full one. What it gives up is the
/// morph between stances and the occasional reaction; what it keeps is the
/// blink and the gaze, which is the whole of what says *this one is alive*
/// from twenty-two points away.
struct CrewLiveChick: View {
    let session: SessionSnapshot
    let roster: CrewRoster
    let paused: Bool
    let frozen: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: CrewCadence.low, paused: paused)) { context in
            let now = roster.seconds(since: context.date)
            let instant = roster.instant(for: session, at: now, frozen: frozen)
            CrewChickAvatar(
                harness: session.key.harness,
                frame: instant.frame,
                isOver: instant.stance == .ended
            )
        }
    }
}

/// The sessions under a lead, as a wrapping row of chicks.
///
/// **This is the collapsed form.** A task card shows its brood by default —
/// that is what makes one card readable as a piece of work with four sessions
/// in it rather than as a card with a number on it. Expanding a card lists the
/// sessions underneath; it does not reveal the chicks, which were there all
/// along.
struct CrewBroodRow<Chick: View>: View {
    let members: [BoardRow]
    var onSelect: (SessionKey) -> Void = { _ in }
    /// One chick, built by the caller — live on the wall, still in a render.
    @ViewBuilder let chick: (BoardRow) -> Chick

    /// How many chicks are drawn before the row says how many more there are.
    ///
    /// Eight. Two rows under a 150-point card, and past that a ninth egg says
    /// less than the number does — the same call the sidebar's harness dots
    /// and the ledger card's member strip both make.
    static var limit: Int { 8 }

    var body: some View {
        if !members.isEmpty {
            FlowLayout(spacing: 3, lineSpacing: 3) {
                ForEach(members.prefix(Self.limit), id: \.key) { member in
                    Button { onSelect(member.key) } label: {
                        chick(member)
                            .overlay(alignment: .topTrailing) { mark(member) }
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.auspex(cornerRadius: 6))
                    .help("\(member.harness.displayName) — \(member.title)")
                }
                if members.count > Self.limit {
                    Text("+\(members.count - Self.limit)")
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(AuspexPalette.textTertiary)
                        .frame(height: CrewChickAvatar.size)
                }
            }
            .accessibilityLabel("\(members.count) sessions on this task")
        }
    }

    /// The one thing a chick has to be able to say for itself: *this one wants
    /// you*. Everything else about a member is on the card or in its tooltip.
    @ViewBuilder
    private func mark(_ member: BoardRow) -> some View {
        if member.needsPerson {
            Circle()
                .fill(AuspexPalette.statePermission)
                .frame(width: 5, height: 5)
                .overlay(Circle().strokeBorder(AuspexPalette.panel, lineWidth: 1))
        } else if member.isDoneReported {
            Circle()
                .fill(AuspexPalette.stateWriting)
                .frame(width: 5, height: 5)
                .overlay(Circle().strokeBorder(AuspexPalette.panel, lineWidth: 1))
        }
    }
}
