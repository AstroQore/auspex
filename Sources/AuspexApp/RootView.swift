import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI
import UserNotifications

/// The main window: sidebar, board, trace.
///
/// Three columns rather than two, because the board and the trace are read
/// together — the whole point of clicking a card is to see what that session
/// just did without losing sight of the other nine. `NavigationSplitView`
/// persists its own column widths between launches, so a person who drags the
/// trace wider gets it back tomorrow.
///
/// The window follows the Mac unless a person said otherwise, and the choice
/// is applied at the root rather than per view so that popovers, menus, and
/// the search field's own chrome — none of which inherit a background colour —
/// inherit the appearance instead. See `AppearanceMode`.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var section: BoardSection? = .live

    /// The one ticker everything animated on the board is a function of.
    ///
    /// Owned by the window rather than by the board so that it survives a
    /// switch between Board and Scene, and so there is visibly one of them.
    @State private var clock = BoardClock()

    /// Where a click on a notification lands.
    ///
    /// Held by the window because the window is what a click has to open onto.
    /// `UNUserNotificationCenter` keeps only a weak delegate, so something with
    /// the app's lifetime has to hold it — and the window outlives every
    /// notification it will ever route.
    @State private var notifications = AgentNotificationDelegate()

    /// Which columns are on screen.
    ///
    /// Bound rather than left to the split view, which is the whole of the fix
    /// for a window that could come up with no sidebar and no way to ask for
    /// one back: the split view persists its own column state, so one stray
    /// ⌘⌥S used to be permanent. ``SidebarVisibility`` owns the rule — every
    /// launch opens with all three, and a state that hides the board is
    /// corrected the moment it is reported.
    @State private var columns = SidebarVisibility.restored(from: nil)

    var body: some View {
        @Bindable var model = environment.board
        @Bindable var environment = environment

        NavigationSplitView(columnVisibility: splitViewColumns) {
            SidebarView(
                section: $section,
                model: model,
                projects: environment.projects,
                tasks: environment.tasks,
                mode: environment.mode,
                isTranslucent: environment.catalog.translucentSidebar
            )
        } content: {
            boardColumn(model: model)
        } detail: {
            SessionTraceView(model: model)
                .navigationSplitViewColumnWidth(min: 360, ideal: 420)
        }
        .auspexAppearance(environment.appearance)
        .environment(clock)
        // Zero-sized, hidden, and in the background so it cannot take a click:
        // it is in the tree only so that the window can be found from inside
        // it. See ``WindowSizingProbe``.
        .background(WindowSizingProbe().frame(width: 0, height: 0))
        .sheet(item: $environment.ignoreDraft) { draft in
            IgnoreRuleSheet(draft: draft, catalog: environment.catalog) {
                environment.ignoreDraft = nil
            }
        }
        .modifier(KillConfirmation(control: environment.control))
        // Over everything, and dismissed by clicking anywhere else. A palette
        // in a sheet would take the window's key focus and animate; this is a
        // panel that appears where a person is already looking.
        .overlay(alignment: .top) {
            if environment.board.isPaletteOpen {
                ZStack(alignment: .top) {
                    Color.black.opacity(0.18)
                        .ignoresSafeArea()
                        .onTapGesture { environment.board.isPaletteOpen = false }
                    CommandPalette(
                        board: environment.board,
                        tasks: environment.tasks,
                        catalog: environment.catalog
                    )
                    .padding(.top, 96)
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { environment.setup.shouldPresent },
            set: { if !$0 { environment.setup.markShown() } }
        )) {
            SetupSheet(
                model: environment.setup,
                detected: environment.harnesses.detected,
                socketPath: environment.mcp?.socketPath,
                onClose: { environment.setup.markShown() }
            )
        }
        .task { environment.start() }
        .task { await clock.run() }
        .task { routeNotifications() }
        // Nothing at all unless `AUSPEX_STALL_LOG=1` asked for it — see
        // ``MainThreadMeter``, which is how this branch's before and after are
        // measured on a machine that is never quiet.
        .task { MainThreadMeter.shared?.start() }
        .onReceive(
            NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)
        ) { _ in
            Task { await environment.shutdown() }
        }
    }

    /// The split view's binding, in the app's own vocabulary.
    ///
    /// A computed binding rather than `$columns` so that the correction is
    /// applied where the split view *writes*: a state that would hide the
    /// board never reaches ``columns`` at all, rather than being fixed up a
    /// frame later, and the window cannot flicker through a picture it is
    /// about to leave.
    private var splitViewColumns: Binding<NavigationSplitViewVisibility> {
        Binding(
            get: { columns.splitViewVisibility },
            set: { visibility in
                let reported = SidebarColumns(visibility)
                columns = SidebarVisibility.correction(for: reported) ?? reported
            }
        )
    }

    /// Points the notification centre's two actions at the board.
    ///
    /// "Show" selects the card the agent called from — which also marks it
    /// seen, so acting on an alert is what stops it being unread. "Copy resume
    /// command" is for the person whose answer belongs in the terminal rather
    /// than in Auspex; it copies and does nothing else, because opening a
    /// terminal on somebody's behalf from a notification is a surprise.
    private func routeNotifications() {
        notifications.onSelect = { key in
            environment.board.selectedKey = key
            environment.board.focusProject(of: key)
        }
        notifications.onCopyResume = { key in
            guard let identity = environment.board.session(for: key)?.identity,
                  case let .available(command, _) = SessionHandoff.resume(for: identity)
            else { return }
            SessionActions.copy(command)
        }
        // Not outside an app bundle: `current()` aborts the process there —
        // see `AgentNotifier.isAvailable`.
        guard AgentNotifier.isAvailable else { return }
        UNUserNotificationCenter.current().delegate = notifications
    }

    @ViewBuilder
    private func boardColumn(model: LiveBoardModel) -> some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            // A task's page replaces the column, header and all: the crumb it
            // draws is the way back, and a board header over a page about one
            // task would be counting a wall nobody is looking at.
            if let unit = model.openUnit {
                TaskDetailView(unit: unit, board: model, tasks: environment.tasks)
            } else {
                boardBody(model: model)
            }
        }
        .background(AuspexPalette.canvas)
        // Every control in this column is drawn by hand, so none of them wants
        // AppKit's blue ring around it. The board's own hairline goes on
        // instead — see `AuspexButtonStyle`.
        .auspexControlFocus()
        .navigationSplitViewColumnWidth(min: 460, ideal: 788)
        // Below the header, not over it. The panel is anchored under the
        // search field it came out of, which is in that bar — hanging it at
        // the column's top edge put it across the heading and the state chips,
        // so the one row that says what is being searched disappeared the
        // moment somebody searched.
        .overlay(alignment: .top) {
            if model.openUnitID == nil, model.searchDidRun || !model.searchHits.isEmpty {
                SearchResultsView(model: model)
                    .padding(.horizontal, 20)
                    .padding(.top, BoardHeader.height + 8)
            }
        }
        // Escape is the way back out of a task, and then out of a project,
        // wherever the pointer is. One key, the nearest thing first: both are
        // "I am done looking at this".
        .onExitCommand {
            if model.openUnitID != nil {
                model.openUnitID = nil
            } else {
                model.focusedProjectKey = nil
            }
        }
        .onChange(of: section) { _, new in
            // "All sessions" is the same board with its history opened out, so
            // selecting it is what opens the collapsed section rather than a
            // separate screen that would show the same cards twice.
            if new == .allSessions { model.showsAllEnded = true }
            if new == .live { model.showsAllEnded = false }
            // A task's page belongs to the board. Going anywhere else closes
            // it rather than leaving it underneath, ready to reappear.
            if new != .live, new != .allSessions { model.openUnitID = nil }
        }
    }

    @ViewBuilder
    private func boardBody(model: LiveBoardModel) -> some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            BoardHeader(model: model, section: section ?? .live)
            Group {
                if section == .harnesses {
                    HarnessesView(
                        model: environment.harnesses,
                        board: model.board,
                        units: model.units,
                        mcp: environment.mcp,
                        onOpenSetup: { environment.setup.present() }
                    )
                } else if section == .projects {
                    ProjectsPageView(
                        catalog: environment.catalog,
                        tree: environment.projects.tree
                    )
                } else if section == .tasks {
                    TasksPageView(model: environment.tasks, board: model)
                } else if section == .settings {
                    // The same pane the Settings window shows. Two ways in
                    // rather than two panes: a person who found the row in the
                    // sidebar should not be told to go and press a shortcut
                    // instead, and a second implementation would be a second
                    // place for a setting to go missing.
                    SettingsSectionView(
                        catalog: environment.catalog,
                        setup: environment.setup,
                        detected: environment.harnesses.detected,
                        socketPath: environment.mcp?.socketPath
                    )
                } else if let section, section.isAvailable {
                    // The mode picker lives in the header, so the container is
                    // a plain switch: adding a way of looking at the board is
                    // a case in `BoardViewMode` and a line here.
                    switch model.viewMode {
                    case .board: BoardView(model: model)
                    case .scene: SceneContainerView(model: model)
                    case .crew: CrewView(model: model, liveliness: environment.catalog.crewLiveliness)
                    case .trajectory: TrajectoryView(model: model)
                    }
                } else {
                    ComingSoonView(section: section ?? .live)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

extension SidebarColumns {
    /// SwiftUI's name for the same three states.
    var splitViewVisibility: NavigationSplitViewVisibility {
        switch self {
        case .all: .all
        case .boardAndTrace: .doubleColumn
        case .traceOnly: .detailOnly
        }
    }

    /// One of SwiftUI's states, read back.
    ///
    /// `.automatic` — what a split view reports before it has decided — is
    /// read as everything, because that is what a three-column window resolves
    /// it to and because guessing "collapsed" from "undecided" is exactly the
    /// mistake this whole type exists to stop.
    init(_ visibility: NavigationSplitViewVisibility) {
        if visibility == .detailOnly {
            self = .traceOnly
        } else if visibility == .doubleColumn {
            self = .boardAndTrace
        } else {
            self = .all
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
/// column carry the board's own chrome — 28 pt rows, a 7 pt selection in the
/// app's accent — whatever it is standing on.
///
/// ## What it is standing on
///
/// The rows are the app's; the ground under them is the system's, by default.
/// A split view already puts its sidebar column on the platform's sidebar
/// material, and Auspex used to paint over it because there was one appearance
/// and the ground had to be one colour everywhere. Letting it show is the most
/// native thing a Mac sidebar can be — it picks up what is behind the window
/// and drains when the window loses key, which is how a person tells at a
/// glance which of two boards is in front — and everything drawn over it is
/// opaque, so nothing that has to be read is read through a blur. Somebody
/// running a wall of these on a second display switches it off in
/// Settings → Appearance and gets the board's own flat canvas instead. See
/// ``SidebarBackground``.
struct SidebarView: View {
    @Binding var section: BoardSection?
    @Bindable var model: LiveBoardModel
    let projects: ProjectsModel
    let tasks: TasksModel
    let mode: AppEnvironment.Mode
    /// Whether the column sits on the system's sidebar material. `false` in
    /// the offscreen renderers, which have no window behind which a material
    /// could sample anything and would draw it as a flat grey rectangle.
    var isTranslucent = false

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
            ) {
                // The Live row is the way back to the whole board: it clears
                // the project binding as well as selecting the section, so
                // "show me everything again" is one click rather than a click
                // and a hunt for the crumb.
                section = .live
                model.focusedProjectKey = nil
            }

            SidebarRow(
                title: BoardSection.allSessions.title,
                count: model.sessionCount,
                isSelected: section == .allSessions
            ) { section = .allSessions }

            projectsHeader

            // `BoardScroll` and not a bare `ScrollView`: it carries the sizing
            // gate that keeps the column's own height question from measuring
            // every row in this tree — see ``ScrollSizeGate``.
            BoardScroll {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ProjectsSidebar(
                        tree: tree,
                        model: projects,
                        focusedProjectKey: model.focusedProjectKey,
                        selectedKey: model.selectedKey,
                        ignoredKeys: model.ignoredKeys,
                        onSelectProject: { key in
                            model.toggleFocusedProject(key)
                            section = .live
                        },
                        onSelectSession: { key in
                            // A session row selects the card *and* binds the
                            // window to its project: the trace, the wall and
                            // the scene then all agree about what is being
                            // looked at.
                            model.selectedKey = key
                            model.focusProject(of: key)
                            section = .live
                        }
                    )
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if mode == .demo { demoNote }

            SidebarRow(
                title: BoardSection.tasks.title,
                count: tasks.openCount,
                isSelected: section == .tasks
            ) { section = .tasks }

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
        .background(SidebarBackground(isTranslucent: isTranslucent))
        .auspexControlFocus()
        // Draggable, and further than it used to be. 180 is where a project
        // name and its live badge still both fit — the tree truncates in the
        // middle, so a long path keeps its ends — and 480 is where somebody
        // who reads the tree rather than the wall can see a whole branch name.
        .navigationSplitViewColumnWidth(min: 180, ideal: 240, max: 480)
        // The system toggle stays. It is plain chrome in a window whose every
        // other pixel is drawn by hand, and it is the only affordance macOS
        // offers for "the sidebar is gone, bring it back" — which is worth
        // more than a tidy title bar. Removing it is what turned one stray
        // ⌘⌥S into a window a person could not navigate.
    }

    /// The rule over the tree, with the way into the Projects page on it.
    ///
    /// A button on the header rather than a row of its own: the tree below it
    /// *is* the list of projects, and a second row saying "Projects" above a
    /// list of projects would be a row that says nothing.
    private var projectsHeader: some View {
        HStack(spacing: 6) {
            Text(BoardSection.projects.title)
                .auspexLabel(AuspexType.labelLarge)
                .foregroundStyle(AuspexPalette.text3)
            Spacer(minLength: 4)
            Button {
                section = .projects
            } label: {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(
                        section == .projects ? AuspexPalette.text : AuspexPalette.text3
                    )
                    .frame(width: 20, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.auspex)
            .help("Manage projects: make one, import from a harness, pin or rename")
        }
        .padding(.horizontal, 10)
        .padding(.top, 14)
        .padding(.bottom, 6)
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
                    .fill(isSelected ? AuspexPalette.selection : .clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.auspex)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.55)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Auspex's own mark: the pixel bird from the app icon, on its dark tile.
///
/// The same drawing at every size the window shows it — the hand-pixelled
/// 32 px icon, scaled with nearest-neighbour so the pixels stay pixels. It is
/// the one brand mark in the window, so it has to be the icon in the Dock.
struct AuspexMark: View {
    var size: CGFloat = 22

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
            .fill(AuspexPalette.bg3)
            .frame(width: size, height: size)
            .overlay {
                if let image = Self.birdImage {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: size, height: size)
                        .clipShape(RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
                } else {
                    Image(systemName: "bird.fill")
                        .font(.system(size: size * 0.5, weight: .bold))
                        .foregroundStyle(AuspexPalette.text)
                }
            }
            .accessibilityLabel("Auspex")
    }

    /// The 64 px render of the icon, loaded once. `nil` only if the bundle is
    /// broken, in which case the symbol stands in.
    nonisolated(unsafe) static let birdImage: NSImage? = {
        guard let url = Bundle.module.url(forResource: "auspex-mark-64", withExtension: "png", subdirectory: "Brand") else { return nil }
        return NSImage(contentsOf: url)
    }()
}

/// Settings, in the board's column.
///
/// It fills the column rather than sitting on it as a 660 pt island. The island
/// was a consequence of the pane being built for a settings *window* and
/// carrying that window's size around with it; now the pane is flexible and the
/// two containers each say how big they are, so the section reads like every
/// other section of the board rather than like a window somebody pasted in.
struct SettingsSectionView: View {
    let catalog: ProjectCatalogModel
    var setup: SetupModel?
    var detected: Set<Harness> = []
    var socketPath: String?
    /// Which pane to open on. Only the offscreen renderer passes one — in the
    /// window, the pane a person last picked is the right answer.
    var initialPane: SettingsPane?

    var body: some View {
        AuspexSettingsView(
            library: SpriteLibrary.shared,
            catalog: catalog,
            setup: setup,
            detected: detected,
            socketPath: socketPath,
            initialPane: initialPane
        )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            // The one part of the board's column made of AppKit's own controls
            // — toggles, steppers, text fields — which draw nothing of their
            // own to say where keyboard focus is. They keep the system ring.
            .auspexSystemControlFocus()
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
                            .buttonStyle(.auspex)
                            Divider().overlay(AuspexPalette.line)
                        }
                    }
                }
                .frame(maxHeight: 320)
            }
        }
        .frame(maxWidth: 560)
        .panelChrome()
        .shadow(color: AuspexPalette.shade, radius: 24, y: 10)
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
