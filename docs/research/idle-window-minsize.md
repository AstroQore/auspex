# What the board still costs while nobody is touching it

**Finding: the largest single cost on the main thread of an idle, visible board
is not the render. It is `NSHostingView.minSize()` — AppKit re-deriving the
window's minimum size, which is a full `sizeThatFits` of everything in the
window, once per applied frame. One fix was tried and did not work; it is
described here so the next attempt starts further along.**

Measured at `77efbb2` (board mode) and on the same tree with the attempted fix.
The earlier notes this follows on from are in `BoardFrameAssembler.swift`
(moving the frame off the main actor) and `ActivityStrip.swift` (the strips on
Core Animation).

## How it was measured

Release bundle from `Scripts/build_app.sh release`, launched in the background
against the real store (`~/.auspex/auspex.db`, 345 MB, ~700 sessions), window
fronted, left alone for two minutes, then `top -l 4 -s 5 -pid <pid>` followed by
`sample <pid> 3`. No user input at any point.

**The machine was not quiet, and this matters.** A dozen agent sessions were
actually running, so the pipeline was producing frames at the coalescer's 8 Hz
ceiling for the whole window, and two other Auspex instances (another agent's
`--demo` builds) were on the same machine. Process CPU came out between 15 %
and 45 % on every run — nowhere near the ≤ 3 % of `AGENTS.md` § 4.1, and the
number moved too much between identical runs to attribute a change to a code
change. **Anything below that is read off the `sample` call graph, which is
about shape rather than about totals.**

A run whose window was occluded or on a sleeping display is not a measurement
of anything: the main thread was 0 % busy in one such run, because a window
nobody composites gets no display cycles. Two of the first four runs were like
that, and both were thrown away.

## The shape, which every run agreed on

```
RunCurrentEventLoopInMode
 └ CA::Transaction::flush_as_runloop_observer
    └ NSDisplayCycleFlush
       ├ __NSWindowGetDisplayCycleObserverForUpdateConstraints_block_invoke
       │   └ -[NSWindow updateConstraintsIfNeeded]
       │      └ NSHostingView._willUpdateConstraintsForSubtree()
       │         └ NSHostingView.SizeConstraints.update(from:)
       │            └ NSHostingView.minSize()                 ← 36 % of the main thread
       │               └ ViewGraph.sizeThatFits(_:)
       │                  └ _FlexFrameLayout → StackLayout → NavigationStackLayout → …
       ├ __NSWindowGetDisplayCycleObserverForLayout_block_invoke   ← 11 %
       └ (elsewhere) NSHostingView.beginTransaction()              ← 29 %
                     └ ViewGraphRootValueUpdater.updateGraph
```

AppKit keeps a window's minimum size in an Auto Layout constraint and refreshes
it from `NSHostingView.minSize()` in every display cycle in which the SwiftUI
graph was dirtied. `minSize()` is `sizeThatFits` of a zero proposal against the
whole hosting view, so **every applied frame pays for a second complete
measurement of the window on top of the render it asked for** — and the number
it computes never changes.

What it costs, from the deepest frames:

- `_ViewList_Elements.makeAllElements`, `_ViewList_Node.applySublists`,
  `ForEachList.applyNodes`, `PlatformItemListTransformModifier`, and long
  towers of `_makeViewList` — SwiftUI **materialising the whole view list** of
  a `ForEach` inside a lazy container. Laziness is a property of *drawing*, not
  of sizing: answering "what size would you be" for a `ScrollView` means asking
  its content for its ideal size, and that builds every element.
- `ResolvedTextFilter.updateValue`, `ResolvedTextHelper.resolve`,
  `Text.resolveAttributedStringAndProperties` — resolving the strings in them.
- `SummaryChips.body` — the header's `ViewThatFits` measuring all five of its
  candidate layouts.

Almost none of it is *our* `body`s: `SessionCard.body`, `TraceRowView.body`
and `TreeRow.body` are single-digit sample counts. It is the element **count**
of the lazy lists, and the two big ones are the trace's `traceItems` (up to
`LiveBoardModel.traceWindow`, 2 000 rows) and `ProjectsSidebar`'s tree
(hundreds of rows on a ~700-session store).

Both of those are in surfaces that are *always* on screen, which is why the
frame-assembly work (`BoardRow`, the narrow `Equatable` properties on
`LiveBoardModel`) reduced this and could not remove it: those changes stop the
graph being dirtied *needlessly*, and on a machine where a dozen sessions
really are moving, it is dirtied legitimately eight times a second anyway.

## The fix that did not work

A custom `Layout` that answers `sizeThatFits` from a constant and never touches
`subviews`, on the theory that a window minimum is a policy (960 × 560 is where
three columns stop making sense) rather than a measurement:

```swift
struct FixedMinimumLayout: Layout {
    let minimum: CGSize
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: max(proposal.width ?? minimum.width, minimum.width),
               height: max(proposal.height ?? minimum.height, minimum.height))
    }
    func placeSubviews(in bounds: CGRect, …) { /* place the child in the whole bounds */ }
}
```

It was tried in place of `.frame(minWidth: 960, minHeight: 560)` at the window
root, and then additionally inside each of the three `NavigationSplitView`
columns. **Neither changed the measured call graph at all** — frames 0 through
24 under `NSHostingView.minSize()` were identical, symbol for symbol, in all
three builds, and the layout's own symbol never appeared in a sample. The
change was reverted.

What that identity says: the hosting view being asked for a minimum is **not**
one those wrappers sit above. Its view graph is rooted at a `_FlexFrameLayout`
that is still there after the only `.frame(minWidth:)` in the app was removed,
with a `NavigationStackLayout` two levels below it — so it is a host SwiftUI
builds for the split view itself, not the one the `WindowGroup` content goes
into.

## What to try next, in order of expected value

1. **Find out which `NSHostingView` it is.** A `debugger()` breakpoint on
   `-[NSWindow updateConstraintsIfNeeded]`, or an `NSView` subtree dump from
   the window, would name it in minutes and would say whether its
   `sizingOptions` can be reached at all. Everything below is guesswork until
   this is answered.
2. **Stop the sizing pass descending into the two long lazy lists.** The trace
   and the sidebar's tree are already `ScrollView` + `LazyVStack` — which is
   the right shape for *drawing* and does nothing for *sizing*, because a
   `ScrollView` asked for an ideal size asks its content for one. Something has
   to answer the zero proposal without building the list: a fixed frame on the
   scroll view, a `Layout` that short-circuits (see above — it has to be
   inside the right hosting view to work), or capping how many rows exist in
   the view list at all rather than only how many are drawn.
3. **Cut the header's `ViewThatFits`.** Five candidate layouts are five
   measurements of the chip row per pass. A single layout that drops chips by
   measuring one string width would be one.
4. **Dirty the graph less often.** Nothing on the always-visible surfaces
   changes eight times a second on purpose; `summary`, `sessionCount` and
   `projects.tree` are `Equatable` and quiet, but `rowGroups` is not, and it is
   read by the board column even when the board is not the mode on screen.

## Scene mode says the wall of cards is not the problem

Sampled the same way, in `--view scene`, on the final tree: main thread 50 %
busy, **32 % of it in the same `minSize()` pass**, and the deepest frames in it
are the same `makeAllElements` / `PlatformItemListTransformModifier` /
`ResolvedTextFilter.updateValue`. The wall of cards is not even in the
hierarchy in that mode.

So the cost is not the board. It is the two long lists that never leave the
window — the trace and the sidebar's tree — rebuilt as a view list from
scratch on every applied frame, in every mode. That is what makes (2) above the
change worth making first.

The deep `_layoutSubtreeWithOldSize` recursion an earlier note reported for the
scene is down to 4 % of the main thread; the scroll-view canvas and the
paused-when-hidden `OfficeSKView` appear to have dealt with it.

A second scene run, whose window happened to be occluded, had a **0 % busy**
main thread and all of the process's CPU in the pipeline — SQLite readers,
`GroupingCoordinator`, `LivenessResolver`. That is the right answer for a
window nobody is looking at, and it is also the reminder that a scene
measurement is worthless without checking that the window was on screen.

## What happened next (`perf/layout-saturation`)

The three questions above were answered, two of them differently from the way
this note expected.

**(1) Which `NSHostingView` is it, and can its `sizingOptions` be reached?**
It cannot, and this is settled rather than untried. `NSHostingView.sizingOptions`
is a Swift property on a *generic* class, so a view found by walking
`NSWindow.contentView` cannot be cast to a type that has it, and there is no
Objective-C entry point to reach it through instead: every hosting view in a
`NavigationSplitView` answers `false` to
`responds(to: NSSelectorFromString("setSizingOptions:"))` on macOS 26.5. What the
walk did find is worth keeping — a split view's columns are separate
`NSHostingView`s, each wrapping SwiftUI's own `HostingScrollView` — and
`WindowSizingProbe` prints it on demand (`AUSPEX_WINDOW_PROBE=1`) so the next
person starts from the tree rather than from a guess.

**(2) Stop the sizing pass descending into the lazy lists.** This was the fix,
and the reason the earlier `FixedMinimumLayout` attempt failed is the one this
note guessed: it was not in front of the thing being asked. A `Layout` that
answers `sizeThatFits` from the proposal and never touches `subviews`, placed
immediately *outside* the scroll view — inside `BoardScroll`, which every
scrolling surface in the app goes through — cuts the chain at
`ScrollViewUtilities.sizeThatFits`. See `ScrollSizeGate`.

**Two things this note did not suspect, and they were larger.**

- `@Observable` compares before it publishes, and the comparison happens *in the
  setter, on the main actor*. `LiveBoardModel.groups` carries whole
  `SessionSnapshot`s, so every applied frame was a deep comparison of every
  session on the board — `SessionSnapshot.__derived_struct_equals` again, coming
  in through the assignment rather than through the render. The assembler now
  reconciles each frame against the last on its own executor and hands back the
  values the model already holds, so the setters' `==` hits the identity fast
  path; a frame that draws the same window is not adopted at all.
- The interval between applied frames was a constant while the cost of applying
  one grows with the board. Past about eighty sessions the window was asked to
  do more work per second than a second contains. It now follows the size.

**How it was measured.** Process CPU cannot tell a frozen window from a busy
machine, and on this machine it moves by tens of per cent between identical
runs — which is what made the numbers above unusable. `MainThreadMeter`
(`AUSPEX_STALL_LOG=1`) times each turn of the main run loop instead: two
`CFRunLoopObserver`s and a subtraction, reported every five seconds. "The
longest the main thread went without reaching `mach_msg`" is what a person
means by *it froze*, and it survives a noisy machine. The scale to measure at
comes from `--demo-scale N`, which multiplies the demo's cast rather than
opening anybody's real store.
