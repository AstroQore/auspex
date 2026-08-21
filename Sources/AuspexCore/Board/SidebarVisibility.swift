import Foundation

/// Which of the window's three columns are on screen.
///
/// A plain enum rather than SwiftUI's `NavigationSplitViewVisibility`, because
/// the rule below is a decision about *this app* — the sidebar is where the
/// projects, the sections and the live tree live, and a window that opens
/// without it is a window with no way to navigate — and a decision worth a
/// test does not belong in a view file that cannot be tested.
///
/// The window maps this onto the SwiftUI value at the one place it binds it.
public enum SidebarColumns: String, Sendable, Codable, Hashable, CaseIterable {
    /// Sidebar, board, trace. What the window is for.
    case all
    /// The sidebar is collapsed; the board and the trace are still there.
    /// Reachable on purpose, with ⌘⌥S or the toolbar's toggle.
    case boardAndTrace
    /// Only the trace. Nothing a person ever asks for — it is what a drag past
    /// the board's minimum width, or a restored window state from a build that
    /// had no toggle, leaves behind.
    case traceOnly

    /// Whether the sidebar is drawn at all.
    public var showsSidebar: Bool { self == .all }

    /// Whether the board — the thing the app exists to show — is drawn.
    public var showsBoard: Bool { self != .traceOnly }
}

/// What the window does about a column state it has been handed.
///
/// ## The bug this exists to make impossible
///
/// `NavigationSplitView` persists its own column state between launches, and
/// the window used to remove the standard sidebar toggle. Between them, one
/// accidental ⌘⌥S — or one drag of the divider to zero — collapsed the sidebar
/// *permanently*: it came back collapsed on every subsequent launch, and there
/// was no control anywhere in the window to bring it back.
///
/// Two rules, and each is one half of the fix:
///
/// - **A launch always opens with everything.** Whatever the previous session
///   left behind, the window a person opens has its sidebar. A collapse is a
///   gesture, not a preference, and a gesture that survives a relaunch with no
///   affordance to undo it is a trap.
/// - **The board is never hidden.** Collapsing the sidebar is something a
///   person can mean; collapsing the sidebar *and* the board is not. That
///   state is corrected the moment it is reported.
///
/// The sidebar staying collapsed *within* a launch is deliberate and is not
/// corrected: the toolbar's toggle is back, so there is now a visible way out,
/// and a toggle that snapped open again would be a toggle that does nothing.
public enum SidebarVisibility {
    /// What the window opens with, given whatever a previous launch persisted.
    ///
    /// Always ``SidebarColumns/all``. The parameter is taken anyway because
    /// the *fact* that the stored value is ignored is the rule, and a function
    /// that never sees it could not be said to ignore it.
    public static func restored(from stored: SidebarColumns?) -> SidebarColumns {
        _ = stored
        return .all
    }

    /// The state to force, when `current` is one the window will not show, or
    /// `nil` when there is nothing to correct.
    public static func correction(for current: SidebarColumns) -> SidebarColumns? {
        current.showsBoard ? nil : .all
    }
}
