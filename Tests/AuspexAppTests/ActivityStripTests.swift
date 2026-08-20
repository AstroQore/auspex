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

/// What the layers under a moving strip actually hold.
///
/// A screenshot cannot answer any of this. A strip whose animation stopped
/// repeating, or which was handed a duration twice what it should be, draws the
/// same first frame as a correct one and diverges only later — so the layer is
/// checked directly, where the mistake is visible immediately.
@Suite("Activity strip layers")
@MainActor
struct ActivityStripViewTests {
    private func view(_ state: SessionState) -> ActivityStripView {
        let view = ActivityStripView(frame: NSRect(x: 0, y: 0, width: 200, height: 6))
        view.apply(StripSpec(rhythm: StripRhythm(state.style.motion), color: state.style.color))
        return view
    }

    private func animation(_ layer: CALayer) -> CAAnimation? {
        layer.animation(forKey: ActivityStripView.animationKey)
    }

    @Test("Every animation repeats forever and is never taken away")
    func animationsOutliveTheirFirstRun() {
        let states: [SessionState] = [
            .thinking,
            .toolCalling(name: "Bash"),
            .delegating(children: 3)
        ]
        for state in states {
            let view = view(state)
            let animated = [view.ground, view.head] + view.ticks
            let running = animated.compactMap(animation)
            #expect(!running.isEmpty, "\(state) should have put an animation on a layer")
            for animation in running {
                #expect(animation.repeatCount == .infinity)
                #expect(animation.isRemovedOnCompletion == false)
            }
        }
    }

    @Test("Thinking breathes on the ground layer's opacity, out and back")
    func breathIsOneAutoreversingOpacityAnimation() {
        let view = view(.thinking)
        guard let breath = animation(view.ground) as? CABasicAnimation else {
            Issue.record("thinking should animate the ground layer's opacity")
            return
        }
        #expect(breath.keyPath == "opacity")
        #expect(breath.fromValue as? Double == 0.25)
        #expect(breath.toValue as? Double == 0.8)
        // Half a second out and half a second back is the one-second period.
        #expect(breath.duration == 0.5)
        #expect(breath.autoreverses)
        #expect(view.head.isHidden)
    }

    @Test("A tool sweeps by travelling the gradient's axis, and does not reverse")
    func sweepMovesTheGradientAxis() {
        let view = view(.toolCalling(name: "Bash"))
        #expect(!view.head.isHidden)
        guard let travel = animation(view.head) as? CAAnimationGroup else {
            Issue.record("a tool should animate the head gradient")
            return
        }
        #expect(travel.duration == 6)
        let paths = travel.animations?.compactMap { ($0 as? CABasicAnimation)?.keyPath } ?? []
        #expect(paths.sorted() == ["endPoint", "startPoint"])
        // A head that slid back would read as scrubbing rather than as progress.
        #expect(travel.animations?.allSatisfy { !$0.autoreverses } == true)
        for step in travel.animations ?? [] {
            #expect(step.timingFunction == CAMediaTimingFunction(name: .linear))
        }
    }

    @Test("Delegating gives every child its own cell, lit in turn")
    func ticksAreOneLayerPerChild() {
        let view = view(.delegating(children: 4))
        #expect(view.ticks.count == 4)
        #expect(view.ground.isHidden)
        for (index, tick) in view.ticks.enumerated() {
            guard let pulse = animation(tick) as? CAKeyframeAnimation else {
                Issue.record("tick \(index) should pulse")
                return
            }
            #expect(pulse.keyPath == "opacity")
            #expect(pulse.duration == 1)
            let values = pulse.values as? [Double] ?? []
            // One value per cell plus a repeat of the first, so the loop closes
            // on the frame it started from rather than jumping at the seam.
            #expect(values.count == 5)
            #expect(values.first == values.last)
            // The cell is the lit one exactly once per pass, at its own turn.
            let lit = values.dropLast().enumerated()
                .filter { $0.element == StripRhythm.tickLit }
                .map(\.offset)
            #expect(lit == [index])
        }
    }

    @Test("A strip nobody can see is not running")
    func offscreenStripsAreStopped() {
        // No window, which is what a card scrolled out of the grid looks like.
        let view = view(.toolCalling(name: "Bash"))
        #expect(view.layer?.speed == 0)
    }

    @Test("Changing state replaces the animation rather than stacking one on it")
    func reapplyingDoesNotLayerAnimations() {
        let view = view(.toolCalling(name: "Bash"))
        let thinking = SessionState.thinking
        view.apply(
            StripSpec(rhythm: StripRhythm(thinking.style.motion), color: thinking.style.color)
        )
        #expect(view.head.animationKeys()?.isEmpty ?? true)
        #expect(view.ground.animationKeys() == [ActivityStripView.animationKey])
    }

    @Test("The strip is invisible to the mouse, so the card underneath gets the click")
    func stripDoesNotSwallowClicks() {
        let view = view(.thinking)
        #expect(view.hitTest(NSPoint(x: 100, y: 3)) == nil)
    }
}
