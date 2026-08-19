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
///
/// The window is dark, always. `.preferredColorScheme(.dark)` is set at the
/// root rather than per view so that popovers, menus, and the search field's
/// own chrome — none of which inherit a background colour — inherit the
/// appearance instead.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var section: BoardSection? = .live

    /// The one ticker everything animated on the board is a function of.
    ///
    /// Owned by the window rather than by the board so that it survives a
    /// switch between Board and Scene, and so there is visibly one of them.
    @State private var clock = BoardClock()

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
                .navigationSplitViewColumnWidth(min: 360, ideal: 420)
        }
        .preferredColorScheme(.dark)
        .environment(clock)
        .task { environment.start() }
        .task { await clock.run() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
            Task { await environment.shutdown() }
        }
    }

    @ViewBuilder
    private func boardColumn(model: LiveBoardModel) -> some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            BoardHeader(model: model, section: section ?? .live)
            Group {
                if section == .harnesses {
                    HarnessesView(model: environment.harnesses, board: model.board)
                } else if section == .settings {
                    // The same pane the Settings window shows. Two ways in
                    // rather than two panes: a person who found the row in the
                    // sidebar should not be told to go and press a shortcut
                    // instead, and a second implementation would be a second
                    // place for a setting to go missing.
                    SettingsSectionView()
                } else if let section, section.isAvailable {
                    // The mode picker lives in the header, so the container is
                    // a plain switch: adding a way of looking at the board is
                    // a case in `BoardViewMode` and a line here.
                    switch model.viewMode {
                    case .board: BoardView(model: model)
                    case .scene: SceneContainerView(model: model)
                    case .crew: CrewView(model: model)
                    }
                } else {
                    ComingSoonView(section: section ?? .live)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(AuspexPalette.canvas)
        .navigationSplitViewColumnWidth(min: 460, ideal: 788)
        .overlay(alignment: .top) {
            if model.searchDidRun || !model.searchHits.isEmpty {
                SearchResultsView(model: model)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
        }
        .onChange(of: section) { _, new in
            // "All sessions" is the same board with its history opened out, so
            // selecting it is what opens the collapsed section rather than a
            // separate screen that would show the same cards twice.
            if new == .allSessions { model.showsAllEnded = true }
            if new == .live { model.showsAllEnded = false }
        }
    }
}

/// The sidebar: where the app is now, what is being worked on, and where the
/// app is going.
///
/// ## Why it is drawn rather than listed
///
/// `List(selection:)` binds one type, and this column has four kinds of row
/// that mean four different things when clicked — a destination *navigates*, a
/// project *filters the wall*, a checkout only opens, a session *selects a
/// card*. Drawing the rows makes those behaviours explicit, and it lets the
/// column carry the board's own chrome — flat ground, 28 pt rows, a 7 pt
/// selection — instead of the system's translucent sidebar material, which
/// would be the one surface in the window that is not Signal Room.
struct SidebarView: View {
    @Binding var section: BoardSection?
    @Bindable var model: LiveBoardModel
    let projects: ProjectsModel
    let mode: AppEnvironment.Mode

    var body: some View {
        // Read, never built: the tree is rebuilt once per applied frame by the
        // model that receives it. Building it here would walk every session on
        // the board on every render, and would write observable state from a
        // body while doing it.
        let tree = projects.tree

        VStack(alignment: .leading, spacing: 2) {
            titleRow

            SidebarRow(
                title: BoardSection.live.title,
                count: model.summary.live,
                isSelected: section == .live
            ) { section = .live }

            SidebarRow(
                title: BoardSection.allSessions.title,
                count: model.board.sessions.count,
                isSelected: section == .allSessions
            ) { section = .allSessions }

            SidebarSectionLabel(BoardSection.projects.title)

            BoardScroll {
                LazyVStack(alignment: .leading, spacing: 2) {
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
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if mode == .demo { demoNote }

            SidebarRow(
                title: BoardSection.harnesses.title,
                isSelected: section == .harnesses
            ) { section = .harnesses }

            SidebarRow(
                title: BoardSection.settings.title,
                isSelected: section == .settings,
                isEnabled: BoardSection.settings.isAvailable,
                trailing: BoardSection.settings.arrivesIn
            ) { section = .settings }
        }
        .padding(.horizontal, 10)
        .padding(.top, 12)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(AuspexPalette.canvas)
        .navigationSplitViewColumnWidth(min: 208, ideal: 232, max: 320)
        .toolbar(removing: .sidebarToggle)
    }

    /// The app's own mark and name, at the top of the column where a person
    /// looks to find out what they are looking at.
    private var titleRow: some View {
        HStack(spacing: 8) {
            AuspexMark(size: 22)
            Text("Auspex")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(AuspexPalette.text)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 12)
    }

    /// A running demo has to say so on screen. Everything on the board is
    /// fabricated, and a screenshot that does not admit it is a lie waiting to
    /// be quoted.
    private var demoNote: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Image(systemName: "theatermasks")
                    .font(.system(size: 9, weight: .semibold))
                Text("Demo replay").font(AuspexType.labelSmall)
            }
            .foregroundStyle(AuspexPalette.stateDelegating)
            Text("Fabricated sessions, in-memory store. No harness store is read.")
                .font(.system(size: 10))
                .foregroundStyle(AuspexPalette.text3)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

/// One destination row: a word, an optional count, and a 7 pt selection.
struct SidebarRow: View {
    let title: String
    var count: Int?
    var isSelected: Bool
    var isEnabled = true
    var trailing: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title)
                    .font(isSelected ? AuspexType.rowStrong : AuspexType.row)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing)
                        .font(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.text3)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .overlay(
                            RoundedRectangle(cornerRadius: 4, style: .continuous)
                                .strokeBorder(AuspexPalette.line, lineWidth: 1)
                        )
                } else if let count {
                    Text("\(count)")
                        .font(AuspexType.monoCount)
                        .auspexTabularDigits()
                        .foregroundStyle(AuspexPalette.text3)
                }
            }
            .foregroundStyle(isSelected ? AuspexPalette.text : AuspexPalette.text2)
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isSelected ? AuspexPalette.bg3 : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// The rule over a block of sidebar rows.
struct SidebarSectionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .auspexLabel(AuspexType.labelLarge)
            .foregroundStyle(AuspexPalette.text3)
            .padding(.horizontal, 10)
            .padding(.top, 14)
            .padding(.bottom, 6)
    }
}

/// Auspex's own mark: an eye on a warning-coloured tile.
///
/// The two colours are the board's two loudest states — a tool is open, and
/// someone is waiting on you — because that is what the app is *for*. It is
/// the only gradient in the window.
struct AuspexMark: View {
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.32, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [AuspexPalette.stateTool, AuspexPalette.statePermission],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: "eye")
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(AuspexPalette.bg0)
            }
            .accessibilityLabel("Auspex")
    }
}

/// Settings, in the board's column.
///
/// The pane is built for a settings *window* and sizes itself, so it sits on
/// the board's ground rather than stretching — the same way the empty state and
/// the coming-soon panel do, so a person who has seen one of those knows what
/// they are looking at.
struct SettingsSectionView: View {
    var body: some View {
        AuspexSettingsView(library: SpriteLibrary.shared)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(BoardSurfaceBackground())
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
            .foregroundStyle(AuspexPalette.text2)

            Text(headline)
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.text)

            Text(explanation)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 420, alignment: .leading)
        .padding(20)
        .panelChrome()
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BoardSurfaceBackground())
    }

    private var headline: String {
        section.arrivesIn.map { "Arrives in \($0)." } ?? section.title
    }

    private var explanation: String {
        switch section {
        case .projects, .allSessions:
            "Sessions grouped by git root and worktree, so three agents in three "
                + "worktrees of one repository read as one project."
        case .harnesses:
            "Which harnesses are installed, where their stores are, and how far "
                + "each tailer has read."
        case .tasks:
            "The shared task board, exposed over MCP so an agent can see what its "
                + "siblings are working on."
        case .settings:
            "Which character each harness wears, and where packages come from."
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
                    .foregroundStyle(AuspexPalette.text3)
                    .padding(12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(model.searchHits) { hit in
                            Button { model.openSearchHit(hit) } label: {
                                SearchHitRow(hit: hit)
                            }
                            .buttonStyle(.plain)
                            Divider().overlay(AuspexPalette.line)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(maxWidth: 560)
        .panelChrome()
        .shadow(color: .black.opacity(0.5), radius: 24, y: 10)
    }

    private var header: some View {
        HStack {
            Text("\(model.searchHits.count) matches")
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.text3)
            Spacer()
            Text("Full text · every harness")
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.text3)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
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
                    .foregroundStyle(AuspexPalette.text)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                HStack(spacing: 5) {
                    Text(hit.role.rawValue)
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.text3)
                    Text(hit.session.sessionID)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text3)
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
