import AuspexCore
import Foundation
import Observation

/// Process-wide dependencies the SwiftUI tree observes.
///
/// A placeholder for now: it carries the resolved paths and version so the
/// window has something real to show. The live session registry, the board
/// snapshot publisher, and the MCP server handle get injected here as the
/// later milestones land — view code should read them from the environment
/// rather than reaching for a singleton.
@MainActor
@Observable
public final class AppEnvironment {
    /// Where Auspex reads and writes its own state.
    public let paths: AuspexPaths

    /// Sidebar destinations. Static until the live board exists.
    public let sections: [BoardSection] = BoardSection.allCases

    public init(paths: AuspexPaths = .default) {
        self.paths = paths
    }

    /// Version string for the menu bar and the placeholder detail pane.
    public var versionDescription: String {
        AuspexVersion.displayString
    }
}

/// Top-level areas of the app. Each becomes a real surface in M1–M3.
public enum BoardSection: String, CaseIterable, Identifiable, Sendable {
    case live
    case projects
    case tasks
    case harnesses
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .live: return "Live"
        case .projects: return "Projects"
        case .tasks: return "Tasks"
        case .harnesses: return "Harnesses"
        case .settings: return "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .live: return "dot.radiowaves.left.and.right"
        case .projects: return "folder"
        case .tasks: return "checklist"
        case .harnesses: return "cpu"
        case .settings: return "gearshape"
        }
    }
}
