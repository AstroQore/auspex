import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// One thing a person can reach, and what happens when they pick it.
///
/// A value rather than a closure so the list can be derived off the main
/// thread's critical path, compared cheaply, and — the reason that matters —
/// *tested*: "what does typing `AUX-3f9k` offer" is a question about a
/// function, and it should not need a window to answer.
struct PaletteItem: Identifiable, Equatable {
    /// The small tag before a row, from its `kind`, which stays an
    /// identifier so a row's identity does not depend on the language.
    static func localizedKind(_ kind: String) -> String {
        switch kind {
        case "task": L10n.Palette.Kind.task
        case "close": L10n.Palette.Kind.close
        case "project": L10n.Palette.Kind.project
        case "session": L10n.Palette.Kind.session
        case "view": L10n.Palette.Kind.view
        case "filter": L10n.Palette.Kind.filter
        default: kind
        }
    }

    enum Action: Equatable {
        /// Open a task's page.
        case openTask(String)
        /// Close a task that is waiting on a person.
        case closeTask(Int64)
        /// Select a session and follow its trace.
        case selectSession(SessionKey)
        /// Bind every surface to one project.
        case focusProject(String)
        /// Show every project again.
        case clearProject
        /// Switch how the board is being looked at.
        case setView(BoardViewMode)
        /// Turn a filter on.
        case filter(TaskFilters)
        /// Fold or open every card's members.
        case toggleSubagents
    }

    let id: String
    let title: String
    /// The line under the title: where the thing is, or what the action does.
    let subtitle: String?
    /// The word on the left, so a list of mixed kinds reads as a list.
    let kind: String
    let action: Action

    static func == (lhs: PaletteItem, rhs: PaletteItem) -> Bool { lhs.id == rhs.id }
}

/// What a query offers.
///
/// Pure, and deliberately small: the palette searches what is on the *frame* —
/// the units, the projects they are in, the sessions inside them — rather than
/// going to the store. Full-text search over transcripts already exists and
/// has its own field; this is for getting somewhere in two keystrokes.
enum PaletteSearch {
    /// How many of each kind to offer. A palette that returns forty rows is a
    /// list, and a list is the thing a palette exists to save you scrolling.
    static let limit = 8

    static func items(
        query raw: String,
        units: [TaskUnit],
        board: BoardSnapshot,
        showsSubagents: Bool
    ) -> [PaletteItem] {
        let query = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var items: [PaletteItem] = []

        // The two that answer "get me out of here", offered first and only
        // when they would do something.
        if query.isEmpty {
            items.append(contentsOf: viewItems())
        }

        for unit in units where matches(unit, query) {
            items.append(
                PaletteItem(
                    id: "open:\(unit.id)",
                    title: unit.title,
                    subtitle: [unit.shortID, unit.status.localizedLabel, projectName(unit, board)]
                        .compactMap { $0 }.joined(separator: " · "),
                    kind: "task",
                    action: .openTask(unit.id)
                )
            )
            if unit.isInReview, let id = unit.origin.taskID {
                items.append(
                    PaletteItem(
                        id: "close:\(id)",
                        title: L10n.Palette.closeTask(title: unit.title),
                        subtitle: L10n.Palette.closeTaskSubtitle(id: unit.shortID),
                        kind: "close",
                        action: .closeTask(id)
                    )
                )
            }
            if items.count > limit * 2 { break }
        }

        var seenProjects: Set<String> = []
        for unit in units {
            guard let key = unit.projectKey, seenProjects.insert(key).inserted else { continue }
            let name = TaskProject.displayName(forKey: key, in: board)
            guard query.isEmpty || name.lowercased().contains(query) else { continue }
            items.append(
                PaletteItem(
                    id: "project:\(key)",
                    title: name,
                    subtitle: TaskProject.subtitle(forKey: key).map(PathDisplay.abbreviate),
                    kind: "project",
                    action: .focusProject(key)
                )
            )
            if seenProjects.count > limit { break }
        }

        if !query.isEmpty {
            for unit in units {
                for member in unit.members where member.title.lowercased().contains(query) {
                    items.append(
                        PaletteItem(
                            id: "session:\(member.key.description)",
                            title: member.title,
                            subtitle: "\(member.harness.displayName) · \(member.state.localizedLabel)",
                            kind: "session",
                            action: .selectSession(member.key)
                        )
                    )
                }
                if items.count > limit * 3 { break }
            }
            items.append(contentsOf: viewItems().filter {
                $0.title.lowercased().contains(query)
            })
            if "subagents".contains(query) || "sessions".contains(query) {
                items.append(
                    PaletteItem(
                        id: "toggle:subagents",
                        title: showsSubagents ? L10n.Palette.hideSubagents : L10n.Board.showSubagents,
                        subtitle: L10n.Palette.subagentsSubtitle,
                        kind: "view",
                        action: .toggleSubagents
                    )
                )
            }
            if "ready".contains(query) {
                items.append(
                    PaletteItem(
                        id: "filter:ready",
                        title: L10n.Palette.readyOnly,
                        subtitle: L10n.Palette.readyOnlySubtitle,
                        kind: "filter",
                        action: .filter(TaskFilters(readyOnly: true))
                    )
                )
            }
        }

        // Deduplicated by id, keeping the first — which is the most specific,
        // because the specific ones are added first.
        var seen: Set<String> = []
        return items.filter { seen.insert($0.id).inserted }
    }

    /// Whether a unit answers to a query: its handle, its title, or a label.
    static func matches(_ unit: TaskUnit, _ query: String) -> Bool {
        guard !query.isEmpty else { return true }
        if unit.shortID.lowercased().contains(query) { return true }
        if unit.title.lowercased().contains(query) { return true }
        return unit.labels.contains { $0.contains(query) }
    }

    private static func projectName(_ unit: TaskUnit, _ board: BoardSnapshot) -> String? {
        unit.projectKey.map { TaskProject.displayName(forKey: $0, in: board) }
    }

    private static func viewItems() -> [PaletteItem] {
        BoardViewMode.pickerOrder.map { mode in
            PaletteItem(
                id: "view:\(mode.rawValue)",
                title: L10n.Palette.switchTo(view: mode.localizedTitle),
                subtitle: nil,
                kind: "view",
                action: .setView(mode)
            )
        }
    }
}

/// ⌘K: a field, a list, and one keystroke to somewhere.
///
/// ## Why a palette on a board with a sidebar
///
/// The sidebar is how you find work you can see. The palette is how you reach
/// work you can name — a handle out of a brief, a project you have not
/// scrolled to, a task you filed this morning — and how you *do* the two or
/// three things that otherwise need a right-click on a card you have to find
/// first. It searches the frame in hand and nothing else: transcripts have
/// their own field, and a palette that went to SQLite would be a palette with
/// a spinner in it.
struct CommandPalette: View {
    @Bindable var board: LiveBoardModel
    let tasks: TasksModel
    let catalog: ProjectCatalogModel

    @State private var query = ""
    @State private var selection = 0
    @FocusState private var isFocused: Bool

    private var items: [PaletteItem] {
        PaletteSearch.items(
            query: query,
            units: board.units,
            board: board.board,
            showsSubagents: board.showsSubagents
        )
    }

    var body: some View {
        VStack(spacing: 0) {
            field
            if items.isEmpty {
                Text(L10n.Palette.nothingMatched)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text3)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                list
            }
        }
        .frame(width: 520)
        .panelChrome()
        .shadow(color: AuspexPalette.shade, radius: 30, y: 12)
        .onAppear { isFocused = true }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private var field: some View {
        HStack(spacing: 8) {
            Image(systemName: "command")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(AuspexPalette.text3)
            TextField(L10n.Palette.placeholder, text: $query)
                .textFieldStyle(.plain)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text)
                .auspexSystemControlFocus()
                .focused($isFocused)
                .onSubmit { run(items.indices.contains(selection) ? items[selection] : nil) }
                .onKeyPress(.downArrow) {
                    selection = min(selection + 1, max(0, items.count - 1))
                    return .handled
                }
                .onKeyPress(.upArrow) {
                    selection = max(selection - 1, 0)
                    return .handled
                }
                .onKeyPress(.escape) {
                    board.isPaletteOpen = false
                    return .handled
                }
        }
        .padding(.horizontal, 14)
        .frame(height: 42)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(items.prefix(12).enumerated()), id: \.element.id) { index, item in
                    Button { run(item) } label: {
                        HStack(spacing: 10) {
                            Text(PaletteItem.localizedKind(item.kind))
                                .font(AuspexType.labelSmall)
                                .foregroundStyle(AuspexPalette.text3)
                                .frame(width: 46, alignment: .leading)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(item.title)
                                    .font(AuspexType.body)
                                    .foregroundStyle(AuspexPalette.text)
                                    .lineLimit(1)
                                if let subtitle = item.subtitle {
                                    Text(subtitle)
                                        .font(AuspexType.monoSmall)
                                        .foregroundStyle(AuspexPalette.text3)
                                        .lineLimit(1)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 7)
                        .background(index == selection ? AuspexPalette.selection : .clear)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.auspex(cornerRadius: 0))
                }
            }
        }
        .frame(maxHeight: 340)
    }

    private func run(_ item: PaletteItem?) {
        guard let item else { return }
        board.isPaletteOpen = false
        switch item.action {
        case .openTask(let id):
            board.openUnitID = id
            if let unit = board.unitIndex[id] { board.selectedKey = unit.lead.key }
        case .closeTask(let id):
            tasks.close(taskID: id)
        case .selectSession(let key):
            board.openUnitID = nil
            board.selectedKey = key
            board.focusProject(of: key)
        case .focusProject(let key):
            board.openUnitID = nil
            board.focusedProjectKey = key
        case .clearProject:
            board.focusedProjectKey = nil
        case .setView(let mode):
            board.openUnitID = nil
            board.viewMode = mode
        case .filter(let filters):
            board.openUnitID = nil
            board.filters = filters
        case .toggleSubagents:
            catalog.setShowsSubagents(!board.showsSubagents)
        }
    }
}
