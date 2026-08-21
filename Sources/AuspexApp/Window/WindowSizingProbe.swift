import AppKit
import SwiftUI

/// Pins the window's minimum size, and says what the window is actually made
/// of when asked.
///
/// ## What this was for, and what it found
///
/// `docs/research/idle-window-minsize.md` names AppKit's constraint pass —
/// `NSWindow.updateConstraintsIfNeeded` → `NSHostingView.minSize()`, a
/// `sizeThatFits` of the whole window against a zero proposal — as the largest
/// single cost on the main thread of an idle board, and its first suggested
/// next step is "find out which `NSHostingView` it is, and whether its
/// `sizingOptions` can be reached at all".
///
/// It cannot. `NSHostingView.sizingOptions` is a Swift property on a *generic*
/// class, so a view discovered by walking `NSWindow.contentView` cannot be cast
/// to a type that has it, and the property has no Objective-C entry point to
/// reach it through instead — every hosting view in a `NavigationSplitView`
/// answers `false` to `responds(to: NSSelectorFromString("setSizingOptions:"))`
/// on macOS 26.5. That road is closed, and this comment is here so the next
/// person does not spend an afternoon finding out again.
///
/// What the walk *did* find is worth keeping, and it is what
/// ``describeHostingViews(in:)`` prints: a split view's three columns are three
/// separate `NSHostingView`s, each with SwiftUI's own `HostingScrollView`
/// inside it. A cost that looks like "the window" is really one column, and
/// knowing which one is the difference between fixing the trace and fixing the
/// sidebar.
///
/// ## What it does do
///
/// Sets `contentMinSize` from the same numbers the SwiftUI root asks for. The
/// window's minimum is a *policy* — below about 980 × 620 three columns stop
/// being three columns — rather than something to be derived from measuring
/// every row in the window, and a window that states its own minimum cannot
/// have one derived out from under it.
struct WindowSizingProbe: NSViewRepresentable {
    /// The smallest window in which the three columns are still three columns.
    static let minimumSize = CGSize(width: 980, height: 620)

    func makeNSView(context: Context) -> NSView { ProbeView() }

    func updateNSView(_ view: NSView, context: Context) {}

    /// A view whose only job is to be in the window, so the window can be
    /// found from inside SwiftUI's own tree.
    private final class ProbeView: NSView {
        override var isHidden: Bool {
            get { true }
            set {}
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            window.contentMinSize = WindowSizingProbe.minimumSize
            guard ProcessInfo.processInfo.environment["AUSPEX_WINDOW_PROBE"] == "1",
                  let contentView = window.contentView
            else { return }
            // On the next turn: the hosting views for the split view's columns
            // are not in the tree yet when the first subview lands in it.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                let text = WindowSizingProbe.describeHostingViews(in: contentView)
                FileHandle.standardOutput.write(Data((text + "\n").utf8))
            }
        }
    }

    /// Every hosting view and scroll view under `root`, as an indented tree.
    ///
    /// A function over a view rather than a print loop, so it can be handed a
    /// hierarchy in a test. Only the classes that matter are listed — a full
    /// dump of a `NavigationSplitView` is two hundred lines of AppKit's own
    /// backdrops and pocket masks, and none of them ever laid anything out.
    static func describeHostingViews(in root: NSView, depth: Int = 0) -> String {
        var lines: [String] = []
        let name = NSStringFromClass(type(of: root))
        if name.contains("HostingView") || name.contains("HostingScrollView") {
            let size = root.frame.size
            lines.append(
                String(repeating: "  ", count: depth)
                    + "auspex-window: \(shortened(name)) "
                    + String(format: "%.0f×%.0f", size.width, size.height)
                    // Recorded because it is the answer to the question the
                    // research note asked, and it is `false` on every one.
                    + " sizingOptions-reachable="
                    + "\(root.responds(to: NSSelectorFromString("setSizingOptions:")))"
            )
        }
        for subview in root.subviews {
            let child = describeHostingViews(in: subview, depth: depth + (lines.isEmpty ? 0 : 1))
            if !child.isEmpty { lines.append(child) }
        }
        return lines.joined(separator: "\n")
    }

    /// A mangled generic class name, cut down to the part that identifies it.
    ///
    /// `_TtGC7SwiftUI13NSHostingViewGVS_15ModifiedContent…` is three lines of
    /// terminal and one useful word.
    private static func shortened(_ name: String) -> String {
        for known in ["HostingScrollView", "NSHostingView", "_NSCoreHostingView"]
        where name.contains(known) {
            return known
        }
        return name
    }
}
