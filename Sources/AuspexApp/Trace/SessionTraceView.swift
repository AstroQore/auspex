import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// The detail pane: who this session is, and everything it has done.
///
/// A header that answers *what am I looking at*, a row of filter chips, and a
/// trace waterfall that follows the tail while new events arrive and stops
/// following the moment the reader scrolls away from it.
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
            filterBar
            Divider().overlay(AuspexPalette.hairlineStrong)
            traceList
        }
    }

    // MARK: Trace

    private var traceList: some View {
        ScrollViewReader { proxy in
            List {
                ForEach(model.traceItems) { item in
                    row(for: item)
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .id(item.id)
                }
                if model.traceItems.isEmpty {
                    emptyTrace
                        .listRowInsets(EdgeInsets())
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(AuspexPalette.canvas)
            .onChange(of: model.traceTailID) { _, tail in
                guard model.followsTail, let tail else { return }
                withAnimation(.easeOut(duration: 0.18)) {
                    proxy.scrollTo(tail, anchor: .bottom)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if !model.followsTail { followButton(proxy: proxy) }
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
                isExpanded: model.expandedRows.contains(entry.id),
                onToggle: {
                    if model.expandedRows.contains(entry.id) {
                        model.expandedRows.remove(entry.id)
                    } else {
                        model.expandedRows.insert(entry.id)
                    }
                }
            )
        }
    }

    /// Turning tail-following back on is one click, and the button only exists
    /// while it is off — a control that is always there but usually inert is
    /// just more to look at.
    private func followButton(proxy: ScrollViewProxy) -> some View {
        Button {
            model.followsTail = true
            if let tail = model.traceTailID {
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(tail, anchor: .bottom) }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.down.to.line")
                    .font(.system(size: 9, weight: .bold))
                Text("Follow").auspexLabel(AuspexType.labelSmall)
            }
            .foregroundStyle(AuspexPalette.textPrimary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .panelChrome(cornerRadius: 12)
        }
        .buttonStyle(.plain)
        .padding(12)
    }

    private var emptyTrace: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(model.isLoadingTrace ? "Loading the event log…" : "No events match the filter.")
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.textSecondary)
            if !model.isLoadingTrace, model.traceFilter.count < TraceEntry.Category.allCases.count {
                Button("Show every category") {
                    model.traceFilter = Set(TraceEntry.Category.allCases)
                }
                .buttonStyle(.link)
                .font(AuspexType.body)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }

    // MARK: Filters

    private var filterBar: some View {
        HStack(spacing: 6) {
            ForEach(TraceEntry.Category.allCases) { category in
                FilterChip(
                    title: category.title,
                    isOn: model.traceFilter.contains(category),
                    count: model.trace.count { $0.category == category }
                ) {
                    if model.traceFilter.contains(category) {
                        // Never let the last chip be switched off: an empty
                        // filter and an empty session look identical, and one
                        // of them is a mistake the reader cannot see.
                        if model.traceFilter.count > 1 { model.traceFilter.remove(category) }
                    } else {
                        model.traceFilter.insert(category)
                    }
                }
            }
            Spacer(minLength: 4)
            Toggle(isOn: $model.followsTail) {
                Text("Follow")
                    .auspexLabel(AuspexType.labelSmall)
                    .fixedSize()
            }
            .toggleStyle(.switch)
            .controlSize(.mini)
            .foregroundStyle(AuspexPalette.textSecondary)
            .fixedSize()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(AuspexPalette.canvasDeep)
    }

    // MARK: Empty

    private var noSelection: some View {
        VStack(spacing: 10) {
            Image(systemName: "list.bullet.indent")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(AuspexPalette.textTertiary)
            Text("Select a session")
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.textSecondary)
            Text("Its prompts, tool calls, and turns appear here as they happen.")
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// A filter chip: a category, whether it is on, and how many rows it holds.
private struct FilterChip: View {
    let title: String
    let isOn: Bool
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title).auspexLabel(AuspexType.labelSmall)
                Text("\(count)")
                    .font(.system(size: 9, weight: .medium, design: .monospaced))
                    .opacity(0.7)
            }
            .foregroundStyle(isOn ? AuspexPalette.textPrimary : AuspexPalette.textTertiary)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                Capsule().fill(isOn ? AuspexPalette.hairlineStrong : Color.clear)
            )
            .overlay(
                Capsule().strokeBorder(AuspexPalette.hairline, lineWidth: isOn ? 0 : 1)
            )
        }
        .buttonStyle(.plain)
        .help(isOn ? "Hide \(title.lowercased())" : "Show \(title.lowercased())")
    }
}

/// The detail pane's header: identity, state, and the facts a person needs
/// before they can act on anything below.
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
            HStack(alignment: .top, spacing: 9) {
                HarnessBadge(harness: session.key.harness, size: 26, isMuted: session.state.isEnded)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.identity.title ?? session.key.sessionID)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(AuspexPalette.textPrimary)
                        .lineLimit(2)
                    HStack(spacing: 6) {
                        Text(session.key.harness.displayName)
                            .auspexLabel(AuspexType.labelSmall)
                            .foregroundStyle(session.key.harness.style.accent)
                        Text(session.key.sessionID)
                            .font(AuspexType.monoSmall)
                            .foregroundStyle(AuspexPalette.textTertiary)
                            .textSelection(.enabled)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Spacer(minLength: 6)

                VStack(alignment: .trailing, spacing: 4) {
                    StatePill(state: session.state, isStale: session.isStale)
                    if session.isStale { StaleTag() }
                }
            }

            if parent != nil || !children.isEmpty {
                lineage
            }

            metadata
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AuspexPalette.panel)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.hairline).frame(height: 1)
        }
    }

    /// Who asked for this session, and what it asked for in turn.
    ///
    /// The parent's chip carries *how the link was worked out*. That is not a
    /// detail: "the parent's own log recorded this spawn" and "these two
    /// processes share an ancestor" are claims of very different strength, and
    /// only one of them can be wrong in a way that files a session under a
    /// repository it has nothing to do with. A header that showed a parent
    /// without saying which invites a reader to trust a guess as a record.
    private var lineage: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let parent {
                HStack(spacing: 6) {
                    Text("Spawned by")
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.textTertiary)
                    LineageChip(
                        session: parent,
                        symbolName: "arrow.turn.left.up",
                        action: { onSelect(parent.key) }
                    )
                    if let link = session.identity.parentLink {
                        Text(link.evidenceLabel)
                            .auspexLabel(AuspexType.labelSmall)
                            .foregroundStyle(AuspexPalette.textTertiary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1.5)
                            .overlay(
                                Capsule().strokeBorder(AuspexPalette.hairline, lineWidth: 1)
                            )
                            .help(link.evidenceDescription)
                    }
                    Spacer(minLength: 0)
                }
            }

            if !children.isEmpty {
                let columns = [
                    GridItem(.adaptive(minimum: 110, maximum: 240), spacing: 5, alignment: .leading)
                ]
                VStack(alignment: .leading, spacing: 4) {
                    Text(children.count == 1 ? "Spawned 1 session" : "Spawned \(children.count) sessions")
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.textTertiary)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
                        ForEach(children, id: \.key) { child in
                            LineageChip(
                                session: child,
                                symbolName: "arrow.turn.down.right",
                                action: { onSelect(child.key) }
                            )
                        }
                    }
                }
            }
        }
    }

    /// The facts, in a grid that reflows rather than a fixed row: the detail
    /// pane is the narrow column and this is the first thing that breaks when
    /// someone drags the divider in.
    private var metadata: some View {
        let columns = [GridItem(.adaptive(minimum: 148, maximum: 260), spacing: 12, alignment: .leading)]
        let worktreeTask = session.identity.worktreePath
            .flatMap(ProjectResolver.agentWorktreeTask(in:))
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            if let projectName {
                MetaField(
                    key: session.identity.gitRoot == nil && session.identity.cwd == nil
                        ? "project (inherited)"
                        : "project",
                    value: projectName,
                    isMono: false
                )
            }
            if let branch = session.identity.gitBranch {
                MetaField(key: "branch", value: branch)
            }
            if let worktreeTask {
                MetaField(
                    key: "worktree task",
                    value: worktreeTask,
                    tint: AuspexPalette.stateWriting
                )
            } else if let worktree = session.identity.worktreePath {
                MetaField(key: "worktree", value: PathDisplay.abbreviate(worktree))
            }
            if let cwd = session.identity.cwd {
                MetaField(key: "cwd", value: PathDisplay.abbreviate(cwd))
            }
            if let model = session.identity.model {
                MetaField(key: "model", value: model)
            }
            if let pid = session.identity.pid {
                MetaField(
                    key: "pid",
                    value: "\(pid)",
                    tint: session.isAlive ? AuspexPalette.stateWriting : AuspexPalette.stateEnded
                )
            }
            MetaField(key: "turns", value: "\(session.turnCount)")
            MetaField(key: "tool calls", value: "\(session.toolCallCount)")
            MetaField(
                key: "tokens in/out",
                value: "\(TokenFormat.compact(session.tokensIn))/\(TokenFormat.compact(session.tokensOut))"
            )
            MetaField(key: "source", value: PathDisplay.abbreviate(session.identity.sourcePath))
        }
    }
}

/// A link to another session in the same tree: its harness, its name, and a
/// direction.
///
/// One component for both directions, because a parent and a child are the same
/// kind of thing to click on and drawing them differently would suggest they
/// are not.
private struct LineageChip: View {
    let session: SessionSnapshot
    let symbolName: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: symbolName)
                    .font(.system(size: 8, weight: .bold))
                HarnessBadge(harness: session.key.harness, size: 12, isMuted: session.state.isEnded)
                Text(title)
                    .font(AuspexType.monoSmall)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Circle()
                    .fill(session.state.style.color)
                    .frame(width: 5, height: 5)
            }
            .foregroundStyle(AuspexPalette.stateDelegating)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .overlay(
                Capsule().strokeBorder(AuspexPalette.stateDelegating.opacity(0.4), lineWidth: 1)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Open \(title) — \(session.state.label)")
    }

    private var title: String {
        if let title = session.identity.title, !title.isEmpty { return title }
        return String(session.key.sessionID.prefix(10))
    }
}
