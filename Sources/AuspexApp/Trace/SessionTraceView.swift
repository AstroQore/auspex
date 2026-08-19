import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The detail pane: who this session is, and everything it has done.
///
/// Three blocks, in the order the questions come: a header that answers *what
/// am I looking at*, a tab bar that answers *what do I want to see of it*, and
/// a waterfall that follows the tail while new rows arrive and stops following
/// the moment the reader scrolls away from it.
struct SessionTraceView: View {
    @Bindable var model: LiveBoardModel

    var body: some View {
        Group {
            if let session = model.selectedSession {
                content(for: session)
            } else {
                noSelection
            }
        }
        .background(AuspexPalette.canvas)
    }

    private func content(for session: SessionSnapshot) -> some View {
        VStack(spacing: 0) {
            SessionHeaderView(
                session: session,
                parent: model.selectedParent,
                children: model.selectedChildren,
                projectName: model.board.projectKey(for: session)
                    .map(BoardGrouping.projectName(forPath:)),
                onSelect: { model.selectedKey = $0 }
            )
            tabBar
            traceList
        }
    }

    // MARK: Tabs

    /// `All · Tools · Prompts · Text · Usage`, and the follow toggle.
    ///
    /// Tabs rather than the chip row this used to be. A chip row let every
    /// combination of five categories be switched on and off, which is
    /// thirty-two states nobody wants and one — everything off — that looks
    /// exactly like a session with nothing in it. A tab is one choice, it is
    /// always in a state that shows something, and `All` is one click away.
    private var tabBar: some View {
        HStack(spacing: 6) {
            ForEach(TraceTab.allCases) { tab in
                Button { model.traceFilter = tab.categories } label: {
                    Text(tab.title)
                        .font(AuspexType.pill)
                        .foregroundStyle(
                            tab.isSelected(model.traceFilter)
                                ? AuspexPalette.text
                                : AuspexPalette.text3
                        )
                        .padding(.horizontal, 9)
                        .frame(height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(
                                    tab.isSelected(model.traceFilter)
                                        ? AuspexPalette.bg3
                                        : .clear
                                )
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Show \(tab.title.lowercased())")
            }
            Spacer(minLength: 6)
            followToggle
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }

    /// Whether the waterfall sticks to the newest row.
    ///
    /// A lit dot and one word, in the same green the board uses for *something
    /// is being made* — because that is what following means here: the pane is
    /// keeping up with a session that is still going.
    private var followToggle: some View {
        Button { model.followsTail.toggle() } label: {
            HStack(spacing: 5) {
                StateDot(
                    color: model.followsTail
                        ? AuspexPalette.stateWriting
                        : AuspexPalette.text3,
                    glows: model.followsTail
                )
                Text("Following")
                    .font(AuspexType.pill)
                    .foregroundStyle(
                        model.followsTail ? AuspexPalette.stateWriting : AuspexPalette.text3
                    )
            }
            .fixedSize()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(
            model.followsTail
                ? "Stop scrolling to the newest row"
                : "Scroll to the newest row as it arrives"
        )
    }

    // MARK: Trace

    /// The waterfall.
    ///
    /// A `ScrollView` over a `LazyVStack` rather than a `List`: a `List` brings
    /// its own row insets, its own separators, its own selection colour, and a
    /// background that has to be argued out of it one modifier at a time — and
    /// after all that it still cannot draw a row with a red outline around it.
    /// The laziness that matters is the `LazyVStack`'s, and that is kept.
    private var traceList: some View {
        ScrollViewReader { proxy in
            BoardScroll {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.traceItems) { item in
                        row(for: item).id(item.id)
                    }
                    if model.traceItems.isEmpty { emptyTrace }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: model.traceTailID) { _, tail in
                guard model.followsTail, let tail else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(tail, anchor: .bottom)
                }
            }
        }
    }

    @ViewBuilder
    private func row(for item: TraceListItem) -> some View {
        switch item {
        case .turnSeparator(let turn, let timestamp):
            TraceTurnSeparator(turn: turn, timestamp: timestamp)
        case .row(let entry):
            TraceRowView(
                entry: entry,
                isWaiting: model.pendingPermissionRowID == entry.id,
                isExpanded: model.expandedRows.contains(entry.id),
                onToggle: {
                    if model.expandedRows.contains(entry.id) {
                        model.expandedRows.remove(entry.id)
                    } else {
                        model.expandedRows.insert(entry.id)
                    }
                }
            )
            .equatable()
        }
    }

    private var emptyTrace: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.isLoadingTrace ? "Loading the event log…" : "Nothing in this view.")
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text2)
            if !model.isLoadingTrace, model.traceFilter.count < TraceEntry.Category.allCases.count {
                Button("Show everything") {
                    model.traceFilter = Set(TraceEntry.Category.allCases)
                }
                .buttonStyle(.link)
                .font(AuspexType.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
    }

    // MARK: Empty

    private var noSelection: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(AuspexPalette.text3)
            Text("Select a session")
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.text2)
            Text("Its prompts, tool calls, and turns appear here as they happen.")
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text3)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// One tab of the trace: a name, and the set of categories it shows.
///
/// The mapping is here rather than in the model because it is a *view* of the
/// filter — the model still holds a set of categories, which is what the
/// rebuild walks and what a future saved view would store.
enum TraceTab: String, CaseIterable, Identifiable {
    case all
    case tools
    case prompts
    case text
    case usage

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .tools: "Tools"
        case .prompts: "Prompts"
        case .text: "Text"
        case .usage: "Usage"
        }
    }

    /// What this tab switches the filter to.
    ///
    /// `all` includes `lifecycle`, which has no tab of its own: session and
    /// turn boundaries are context for everything else rather than a thing a
    /// person goes looking for.
    var categories: Set<TraceEntry.Category> {
        switch self {
        case .all: Set(TraceEntry.Category.allCases)
        case .tools: [.tools]
        case .prompts: [.prompts]
        case .text: [.text]
        case .usage: [.usage]
        }
    }

    func isSelected(_ filter: Set<TraceEntry.Category>) -> Bool {
        filter == categories
    }
}

/// The detail pane's header: identity, state, and the facts a person needs
/// before they can act on anything below.
///
/// Four rows, and they are four different kinds of fact: who this is, where it
/// is, what it is connected to, and how much of it there has been. Keeping
/// them in that order is what lets a reader stop as soon as they have what
/// they came for.
struct SessionHeaderView: View {
    let session: SessionSnapshot
    let parent: SessionSnapshot?
    /// What this session spawned, from the board's forest — so a `codex exec`
    /// the process table linked appears next to a subagent the log recorded.
    var children: [SessionSnapshot] = []
    /// The project this session groups under, inherited from an ancestor when
    /// it recorded no directory of its own.
    var projectName: String?
    let onSelect: (SessionKey) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            identity
            chips
            stats
        }
        .padding(.horizontal, 18)
        .padding(.top, 16)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1)
        }
    }

    /// The mark, the title, the identity line, and the state.
    private var identity: some View {
        HStack(alignment: .center, spacing: 10) {
            HarnessBadge(harness: session.key.harness, size: 26, isMuted: session.state.isEnded)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(AuspexType.paneTitle)
                    .foregroundStyle(AuspexPalette.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Text(identityLine)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 6)
            if session.isStale { StaleTag() }
            StatePill(state: session.state, isStale: session.isStale)
                .fixedSize()
        }
    }

    /// The full name, never an abbreviation, and the three identifiers a
    /// person needs to find this session in their own terminal.
    private var identityLine: String {
        var parts = [session.key.harness.displayName, String(session.key.sessionID.prefix(8))]
        if let pid = session.identity.pid { parts.append("pid \(pid)") }
        if let model = session.identity.model { parts.append(model) }
        return parts.joined(separator: " · ")
    }

    private var title: String {
        if let title = session.identity.title, !title.isEmpty { return title }
        return session.key.sessionID
    }

    /// Where the work is, and what it is connected to.
    ///
    /// The parent's chip carries *how the link was worked out*. That is not a
    /// detail: "the parent's own log recorded this spawn" and "these two
    /// processes share an ancestor" are claims of very different strength, and
    /// only one of them can be wrong in a way that files a session under a
    /// repository it has nothing to do with.
    private var chips: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            if let projectName {
                FactChip(place(projectName))
            }
            if let cwd = session.identity.cwd ?? session.identity.gitRoot {
                FactChip(PathDisplay.abbreviate(cwd), isMono: true)
            }
            if let worktreeTask = session.identity.worktreePath
                .flatMap(ProjectResolver.agentWorktreeTask(in:)) {
                FactChip(worktreeTask, tint: AuspexPalette.stateWriting, isMono: true)
            }
            if let parent {
                Button { onSelect(parent.key) } label: {
                    FactChip(tint: AuspexPalette.stateDelegating) {
                        Text("↑ \(name(of: parent))")
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(
                    session.identity.parentLink
                        .map { "Spawned by \(name(of: parent)) — \($0.evidenceDescription)" }
                        ?? "Open the session that spawned this one"
                )
            }
            if !children.isEmpty {
                FactChip(
                    children.count == 1 ? "↳ 1 child" : "↳ \(children.count) children",
                    tint: AuspexPalette.stateDelegating
                )
            }
        }
    }

    private func place(_ project: String) -> String {
        guard let branch = session.identity.gitBranch, !branch.isEmpty else { return project }
        return "\(project) · \(branch)"
    }

    private func name(of session: SessionSnapshot) -> String {
        if let title = session.identity.title, !title.isEmpty { return title }
        return String(session.key.sessionID.prefix(10))
    }

    /// How much of this there has been. One row, four numbers, no keys longer
    /// than the values they label.
    private var stats: some View {
        HStack(spacing: 16) {
            HStack(spacing: 5) {
                Text("elapsed")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                ElapsedLabel(
                    since: session.startedAt ?? session.lastEventAt,
                    until: session.endedAt,
                    font: AuspexType.monoClock
                )
            }
            MetaField(key: "turns", value: "\(session.turnCount)")
            MetaField(key: "tools", value: "\(session.toolCallCount)")
            MetaField(
                key: "tokens",
                value: "\(TokenFormat.compact(session.tokensIn)) / "
                    + "\(TokenFormat.compact(session.tokensOut))"
            )
            Spacer(minLength: 0)
        }
    }
}
