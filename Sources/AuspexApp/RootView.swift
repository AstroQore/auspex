import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The main window: sidebar, board, trace.
///
/// Three columns rather than two, because the board and the trace are read
/// together — the whole point of clicking a card is to see what that session
/// just did without losing sight of the other nine. `NavigationSplitView`
/// persists its own column widths between launches, so a person who drags the
/// trace wider gets it back tomorrow.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var section: BoardSection? = .live

    var body: some View {
        @Bindable var model = environment.board

        NavigationSplitView {
            SidebarView(
                section: $section,
                model: model,
                projects: environment.projects,
                mode: environment.mode
            )
        } content: {
            boardColumn(model: model)
        } detail: {
            SessionTraceView(model: model)
                .navigationSplitViewColumnWidth(min: 340, ideal: 460)
        }
        .task { environment.start() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
            Task { await environment.shutdown() }
        }
    }

    @ViewBuilder
    private func boardColumn(model: LiveBoardModel) -> some View {
        @Bindable var model = model

        Group {
            if section == .harnesses {
                HarnessesView(model: environment.harnesses, board: model.board)
            } else if let section, section.isAvailable {
                LiveSectionView(model: model)
            } else {
                ComingSoonView(section: section ?? .live)
            }
        }
        .navigationSplitViewColumnWidth(min: 420, ideal: 760)
        .navigationTitle(navigationTitle)
        .navigationSubtitle(subtitle(for: model))
        .searchable(
            text: $model.searchQuery,
            placement: .toolbar,
            prompt: "Search every transcript"
        )
        .overlay(alignment: .top) {
            if model.searchDidRun || !model.searchHits.isEmpty {
                SearchResultsView(model: model)
                    .padding(.horizontal, 12)
                    .padding(.top, 10)
            }
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("Group by", selection: $model.groupBy) {
                    ForEach(BoardGroupBy.allCases) { option in
                        Text(option.title).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 210)
                .help("Divide the board into sections")
            }
        }
    }

    private var navigationTitle: String {
        environment.mode == .demo ? "Auspex — Demo" : "Auspex"
    }

    private func subtitle(for model: LiveBoardModel) -> String {
        let counts = model.board.counts
        guard counts.live > 0 || counts.ended > 0 else { return "Nothing running" }
        var parts = ["\(counts.live) live"]
        if counts.waitingPermission > 0 { parts.append("\(counts.waitingPermission) blocked") }
        if counts.delegating > 0 { parts.append("\(counts.delegating) delegating") }
        return parts.joined(separator: " · ")
    }
}

/// The sidebar: where the app is now, what is being worked on, and where the
/// app is going.
///
/// Two lists in one column. The destinations at the top are a table of
/// contents and never change; the project tree under them is the live half,
/// and it is the reason the column is wider than a list of five words needs.
/// `Projects` is not one of the destinations — the tree *is* the projects
/// section, and a row that pushed a second view of the same thing would be a
/// row that has to explain itself.
struct SidebarView: View {
    @Binding var section: BoardSection?
    @Bindable var model: LiveBoardModel
    let projects: ProjectsModel
    let mode: AppEnvironment.Mode

    /// The destinations, minus the one the tree below already is.
    private var destinations: [BoardSection] {
        BoardSection.allCases.filter { $0 != .projects }
    }

    var body: some View {
        let tree = projects.tree(for: model.board)

        List(selection: $section) {
            Section {
                ForEach(destinations) { item in
                    SidebarRow(section: item, liveCount: item == .live ? model.board.counts.live : nil)
                        .tag(item)
                        .disabled(!item.isAvailable)
                }
            } header: {
                Text("Board")
                    .auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.textTertiary)
            }

            Section {
                ProjectsSidebar(
                    tree: tree,
                    model: projects,
                    projectFilter: model.projectFilter,
                    selectedKey: model.selectedKey,
                    onSelectProject: { key in
                        model.toggleProjectFilter(key)
                        section = .live
                    },
                    onSelectSession: { key in
                        model.selectedKey = key
                        section = .live
                    }
                )
            } header: {
                projectsHeader(tree: tree)
            }

            if mode == .demo {
                Section {
                    demoNote
                } header: {
                    Text("Mode")
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.textTertiary)
                }
            }
        }
        .navigationSplitViewColumnWidth(min: 200, ideal: 244, max: 340)
        .navigationTitle("Auspex")
    }

    /// The tree's header, which doubles as the filter's off switch — the only
    /// place a person who has filtered the wall can reliably find one.
    private func projectsHeader(tree: ProjectTree) -> some View {
        HStack(spacing: 5) {
            Text(BoardSection.projects.title)
                .auspexLabel(AuspexType.labelSmall)
            Text("\(tree.projects.count)")
                .font(.system(size: 9, weight: .medium, design: .monospaced))
            Spacer(minLength: 4)
            if model.projectFilter != nil {
                Button { model.projectFilter = nil } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "line.3.horizontal.decrease")
                            .font(.system(size: 8, weight: .bold))
                        Text("Clear").auspexLabel(AuspexType.labelSmall)
                    }
                    .foregroundStyle(AuspexPalette.stateThinking)
                }
                .buttonStyle(.plain)
                .help("Show every project on the board")
            }
        }
        .foregroundStyle(AuspexPalette.textTertiary)
    }

    /// A running demo has to say so on screen. Everything on the board is
    /// fabricated, and a screenshot that does not admit it is a lie waiting to
    /// be quoted.
    private var demoNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "theatermasks")
                    .font(.system(size: 9, weight: .semibold))
                Text("Demo replay").auspexLabel(AuspexType.labelSmall)
            }
            .foregroundStyle(AuspexPalette.stateDelegating)
            Text("Fabricated sessions, in-memory store. No harness store is read.")
                .font(.system(size: 10))
                .foregroundStyle(AuspexPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
    }
}

/// One sidebar row.
private struct SidebarRow: View {
    let section: BoardSection
    let liveCount: Int?

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: section.systemImage)
                .font(.system(size: 11))
                .frame(width: 15)
            Text(section.title)
                .font(AuspexType.body)
            Spacer(minLength: 4)
            if let liveCount, liveCount > 0 {
                Text("\(liveCount)")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(AuspexPalette.textPrimary)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(AuspexPalette.stateThinking.opacity(0.35)))
            } else if let milestone = section.arrivesIn {
                Text(milestone)
                    .auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .overlay(
                        Capsule().strokeBorder(AuspexPalette.hairline, lineWidth: 1)
                    )
            }
        }
    }
}

/// What a not-yet-built section says for itself.
///
/// Names the milestone and what will be there, because "coming soon" tells a
/// reader nothing they could not already see.
struct ComingSoonView: View {
    let section: BoardSection

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Image(systemName: section.systemImage)
                    .font(.system(size: 11, weight: .semibold))
                Text(section.title).auspexLabel(AuspexType.labelLarge)
            }
            .foregroundStyle(AuspexPalette.textSecondary)

            Text(headline)
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.textPrimary)

            Text(explanation)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(20)
        .panelChrome()
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BoardSurfaceBackground())
    }

    private var headline: String {
        section.arrivesIn.map { "Arrives in \($0)." } ?? section.title
    }

    private var explanation: String {
        switch section {
        case .projects:
            "Sessions grouped by git root and worktree, so three agents in three "
                + "worktrees of one repository read as one project."
        case .harnesses:
            "Which harnesses are installed, where their stores are, and how far "
                + "each tailer has read."
        case .tasks:
            "The shared task board, exposed over MCP so an agent can see what its "
                + "siblings are working on."
        case .settings:
            "Retention, which harnesses to index, and the optional local hooks."
        case .live:
            "The live board."
        }
    }
}

/// Search results, over the board.
///
/// A panel rather than a separate destination: a search is a way of getting to
/// a session, and pushing a whole screen for it would mean losing the board to
/// find something on it.
struct SearchResultsView: View {
    let model: LiveBoardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if model.searchHits.isEmpty {
                Text("Nothing matched.")
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.searchHits) { hit in
                            Button { model.openSearchHit(hit) } label: {
                                SearchHitRow(hit: hit)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(AuspexPalette.hairline)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(maxWidth: 560)
        .panelChrome()
        .shadow(color: .black.opacity(0.35), radius: 18, y: 6)
    }

    private var header: some View {
        HStack {
            Text("\(model.searchHits.count) matches")
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
            Spacer()
            Text("Full text · every harness")
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(AuspexPalette.canvasDeep)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.hairline).frame(height: 1)
        }
    }
}

private struct SearchHitRow: View {
    let hit: SearchHit

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            HarnessBadge(harness: hit.harness, size: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(hit.snippet)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Text(hit.role.rawValue)
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.textTertiary)
                    Text(hit.session.sessionID)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }
}
