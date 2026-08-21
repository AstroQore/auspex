import CoreGraphics
import Foundation

/// The panes of Settings, and what each one is for in one line.
///
/// ## Why the copy lives here and not in the views
///
/// Settings used to be a `TabView`, and a `TabView` knows the *name* of a pane
/// but nothing else about it. So the one subtitle the window had was written
/// once, next to the pane that happened to exist at the time, and stayed there
/// while five more panes grew underneath it — which is how every tab came to be
/// introduced as "characters, and where packages come from".
///
/// A pane is therefore a value with both halves of its own heading, in one
/// place, where a new case cannot compile without answering the question. The
/// order is the order the strip draws them in, and it is deliberate: what
/// Auspex has *written into other people's files* comes first, and what it
/// draws for itself comes after.
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable, Codable {
    case agents
    case appearance
    case characters
    case scene
    case crew
    case ignore
    case updates

    public var id: String { rawValue }

    /// The name on the strip. One word wherever one word will do — six
    /// segments have to fit a 460 pt column.
    public var title: String {
        switch self {
        case .agents: "Agents"
        case .appearance: "Appearance"
        case .characters: "Characters"
        case .scene: "Scene"
        case .crew: "Crew"
        case .ignore: "Ignore"
        case .updates: "Updates"
        }
    }

    /// The line under the title. A sentence about *this* pane, in the same
    /// voice the board's own headings use: what the thing is, not what to do
    /// about it.
    public var subtitle: String {
        switch self {
        case .agents:
            "What Auspex has written into each harness, and how to take it back."
        case .appearance:
            "Light and dark, and one accent in both."
        case .characters:
            "Which character each harness wears, and where packages come from."
        case .scene:
            "How much map there is: the office, and the places people walk to."
        case .crew:
            "How often the wall of faces moves."
        case .ignore:
            "Everything the board is not showing, and why."
        case .updates:
            "Which channel this copy follows, and when it last asked."
        }
    }

    /// The SF Symbol beside the title.
    public var systemImage: String {
        switch self {
        case .agents: "point.3.connected.trianglepath.dotted"
        case .appearance: "circle.lefthalf.filled"
        case .characters: "person.and.background.dotted"
        case .scene: "map"
        case .crew: "face.smiling"
        case .ignore: "eye.slash"
        case .updates: "arrow.down.circle"
        }
    }

    /// The panes to draw when there is no app behind the window — the
    /// offscreen renderers and the previews, which have no `SetupModel` and
    /// therefore nothing to show on Agents.
    public static func available(hasSetup: Bool) -> [SettingsPane] {
        hasSetup ? allCases : allCases.filter { $0 != .agents }
    }

    /// How wide this pane's content is allowed to get.
    ///
    /// Two answers, because Settings holds two kinds of page. A pane that is
    /// paragraphs and switches is *prose*, and prose has a measure: a line run
    /// to 1,300 points is a line nobody's eye can get back to the start of, so
    /// it stops at ``proseMeasure`` and the rest of the window stays as margin
    /// — margin on both sides, which is a decision, rather than all of it on
    /// the right, which is what a left-aligned cap looks like.
    ///
    /// Agents and Characters are not prose. They are a *grid of cards*, and a
    /// grid gets better with width: capping it at a paragraph's measure is what
    /// left nine harness cards in one column down the middle of a 1,680 pt
    /// window with room for three abreast. So they get ``gridMeasure``, which
    /// is three 440 pt cards and the gaps between them.
    public var measure: CGFloat {
        switch self {
        case .agents, .characters: Self.gridMeasure
        case .appearance, .scene, .crew, .ignore, .updates: Self.proseMeasure
        }
    }

    /// As wide as a column of settings copy is worth running.
    public static let proseMeasure: CGFloat = 1_100
    /// Three cards abreast, their gaps, and the pane's own padding.
    public static let gridMeasure: CGFloat = 1_400
}
