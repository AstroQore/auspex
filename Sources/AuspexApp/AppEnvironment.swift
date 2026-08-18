import AuspexCore
import Foundation
import Observation

/// Process-wide dependencies the SwiftUI tree observes.
///
/// It carries the resolved paths, the version, and the open database. The
/// live board is not wired up yet: `AuspexCore` has a `SessionRegistry` that
/// turns an `AgentEvent` stream into `BoardSnapshot` frames, but nothing
/// produces that stream until the source adapters land, and there is no view
/// to render the frames.
///
/// TODO: once the ingest pipeline exists, hold a `SessionRegistry` here,
/// start it with the merged event stream, and expose a `@MainActor` board
/// model that consumes `registry.boardSnapshots`. View code should read that
/// model from the environment rather than reaching for a singleton, and no
/// view should ever touch `store` directly.
@MainActor
@Observable
public final class AppEnvironment {
    /// Where Auspex reads and writes its own state.
    public let paths: AuspexPaths

    /// The local database, or `nil` when it could not be opened.
    ///
    /// A failure here is not fatal: an app that cannot open its store can
    /// still show the window and say why, which is more useful than a launch
    /// that dies before drawing anything.
    public let store: AuspexStore?

    /// Why ``store`` is `nil`, for the settings pane to show.
    public let storeErrorDescription: String?

    /// Sidebar destinations. Static until the live board exists.
    public let sections: [BoardSection] = BoardSection.allCases

    public init(paths: AuspexPaths = .default) {
        self.paths = paths
        do {
            self.store = try AuspexStore(paths: paths)
            self.storeErrorDescription = nil
        } catch {
            self.store = nil
            self.storeErrorDescription = String(describing: error)
        }
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
