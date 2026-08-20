import AgentSessionLive
import SwiftUI
import Testing

@testable import AuspexApp

/// What the strip under a card does for each state.
///
/// The rhythms are pinned here rather than looked at, because the thing that
/// makes them cheap — one `CAAnimation` added once and never re-applied — is
/// also the thing that makes a mistake invisible: a strip given the wrong
/// rhythm still animates, and a strip re-applied on every frame still looks
/// right while costing what the old one did.
@Suite("Activity strip")
@MainActor
struct ActivityStripTests {
    @Test("A session that is not doing anything does not move")
    func stillStates() {
        #expect(StripRhythm(SessionState.idle.style.motion).moves == false)
        #expect(StripRhythm(SessionState.ended(reason: .exited).style.motion).moves == false)
    }

    @Test("Needs you is a still bar, because the card already glows")
    func needsYouIsStill() {
        let rhythm = StripRhythm(SessionState.waitingPermission(tool: "Bash").style.motion)
        #expect(rhythm == .bar(opacity: 0.9))
        #expect(rhythm.moves == false)
    }

    @Test("Thinking breathes once a second, between a quarter and four fifths")
    func thinkingBreathes() {
        #expect(StripRhythm(SessionState.thinking.style.motion)
            == .breathe(from: 0.25, to: 0.8, period: 1))
    }

    @Test("A tool sweeps wider than a file write, and both cross in six seconds")
    func sweepWidths() {
        guard case .sweep(let tool, let toolPeriod) =
            StripRhythm(SessionState.toolCalling(name: "Bash").style.motion),
              case .sweep(let write, let writePeriod) =
            StripRhythm(SessionState.writingFile(path: "/Users/example/a.swift").style.motion)
        else {
            Issue.record("tool and writing states should both sweep")
            return
        }
        #expect(tool > write)
        #expect(toolPeriod == 6)
        #expect(writePeriod == 6)
    }

    @Test("One child is a lit cell; several are a sequence")
    func delegating() {
        #expect(StripRhythm(SessionState.delegating(children: 1).style.motion)
            == .bar(opacity: 0.95))
        #expect(StripRhythm(SessionState.delegating(children: 3).style.motion)
            == .ticks(count: 3, step: 0.25))
    }

    /// The guard that keeps a card's ordinary redraw from restarting the
    /// animation under it. If this ever compares unequal for two frames of the
    /// same state, every strip on the board silently jumps back to its first
    /// frame whenever its session says anything.
    @Test("Two frames of the same state ask the layer for nothing")
    func specIsStableAcrossFrames() {
        let state = SessionState.toolCalling(name: "Bash")
        let one = StripSpec(
            rhythm: StripRhythm(state.style.motion),
            color: state.style.color
        )
        let two = StripSpec(
            rhythm: StripRhythm(state.style.motion),
            color: state.style.color
        )
        #expect(one == two)
    }

    @Test("A state change or a colour change does reach the layer")
    func specTracksWhatMatters() {
        let tool = SessionState.toolCalling(name: "Bash")
        let base = StripSpec(rhythm: StripRhythm(tool.style.motion), color: tool.style.color)
        var thinking = base
        thinking.rhythm = StripRhythm(SessionState.thinking.style.motion)
        var recoloured = base
        recoloured.color = SessionState.thinking.style.color

        #expect(thinking != base)
        #expect(recoloured != base)
    }

    /// The gate that decides whether a strip is an `NSView` at all. Getting it
    /// wrong is expensive in one direction — a wall of finished sessions each
    /// hosting a platform view — and wrong-looking in the other: a card SwiftUI
    /// fades or desaturates cannot have its strip in a layer, because the
    /// effect would not reach it.
    @Test("Only a strip that moves is worth a layer")
    func onlyMovingStatesLeaveTheGraph() {
        let moving: [SessionState] = [
            .thinking,
            .toolCalling(name: "Bash"),
            .writingFile(path: "/Users/example/a.swift"),
            .delegating(children: 3)
        ]
        let still: [SessionState] = [
            .idle,
            .ended(reason: .exited),
            .waitingPermission(tool: "Bash"),
            .delegating(children: 1)
        ]
        for state in moving {
            #expect(ActivityStrip(motion: state.style.motion, color: state.style.color)
                .needsLayer(reduceMotion: false, isSnapshotRender: false))
        }
        for state in still {
            #expect(!ActivityStrip(motion: state.style.motion, color: state.style.color)
                .needsLayer(reduceMotion: false, isSnapshotRender: false))
        }
    }

    @Test("Reduce Motion, a stale session and a screenshot all stay in SwiftUI")
    func nothingLeavesTheGraphWithoutReason() {
        let busy = SessionState.toolCalling(name: "Bash")
        let strip = ActivityStrip(motion: busy.style.motion, color: busy.style.color)
        let stale = ActivityStrip(motion: busy.style.motion, color: busy.style.color, isStale: true)

        #expect(!strip.needsLayer(reduceMotion: true, isSnapshotRender: false))
        #expect(!strip.needsLayer(reduceMotion: false, isSnapshotRender: true))
        #expect(!stale.needsLayer(reduceMotion: false, isSnapshotRender: false))
    }
}
