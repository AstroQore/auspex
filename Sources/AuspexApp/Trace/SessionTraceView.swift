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
                onSelectParent: { model.selectedKey = $0 }
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
    let onSelectParent: (SessionKey) -> Void

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

            if let parent {
                parentLink(parent)
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

    private func parentLink(_ parent: SessionSnapshot) -> some View {
        Button {
            onSelectParent(parent.key)
        } label: {
            HStack(spacing: 5) {
                Image(systemName: "arrow.turn.left.up")
                    .font(.system(size: 8, weight: .bold))
                Text("Spawned by").auspexLabel(AuspexType.labelSmall)
                Text(parent.identity.title ?? parent.key.sessionID)
                    .font(AuspexType.monoSmall)
                    .lineLimit(1)
            }
            .foregroundStyle(AuspexPalette.stateDelegating)
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .overlay(
                Capsule().strokeBorder(AuspexPalette.stateDelegating.opacity(0.4), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .help("Open the parent session")
    }

    /// The facts, in a grid that reflows rather than a fixed row: the detail
    /// pane is the narrow column and this is the first thing that breaks when
    /// someone drags the divider in.
    private var metadata: some View {
        let columns = [GridItem(.adaptive(minimum: 148, maximum: 260), spacing: 12, alignment: .leading)]
        return LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            if let cwd = session.identity.cwd {
                MetaField(key: "cwd", value: PathDisplay.abbreviate(cwd))
            }
            if let branch = session.identity.gitBranch {
                MetaField(key: "branch", value: branch)
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
            if !session.children.isEmpty {
                MetaField(key: "children", value: "\(session.children.count)")
            }
            MetaField(key: "source", value: PathDisplay.abbreviate(session.identity.sourcePath))
        }
    }
}
