import AgentSessionKit
import AuspexCore
import SwiftUI

/// The Harnesses page: a rack of the harnesses Auspex watches, one row each.
///
/// ## What it is for
///
/// One question, asked from two directions. *Why is this harness not on my
/// board* — which is answered by whether its store exists, whether an adapter
/// reads it, and when it last did anything. And *what can this harness reach* —
/// which is answered by its MCP configuration, and which is the question the
/// task board depends on.
///
/// ## Read-only, and it says so
///
/// Every file behind this page belongs to another tool. The page says that
/// where a person can see it, because a status page that shows configuration is
/// exactly the kind of page a person expects to be able to *edit*, and the
/// honest thing is to say up front that this one will not.
struct HarnessesView: View {
    let model: HarnessStatusModel
    let board: BoardSnapshot
    /// The MCP listener, when there is one. `nil` in a render with no app
    /// behind it.
    var mcp: MCPController?
    /// Opens the setup sheet. `nil` where there is nowhere to present one.
    var onOpenSetup: (() -> Void)?

    var body: some View {
        HarnessesPage(
            rows: model.rows(board: board),
            mcp: mcp,
            onOpenSetup: onOpenSetup
        )
        .task { await model.refresh() }
    }
}

/// The page itself, over values rather than over a model.
///
/// Split out so the page can be rendered against a fixed set of rows — which
/// is what the documentation screenshots do, and what keeps a real machine's
/// configuration out of a public repository.
struct HarnessesPage: View {
    let rows: [HarnessStatus]
    var mcp: MCPController?
    var onOpenSetup: (() -> Void)?

    var body: some View {
        BoardScroll {
            VStack(alignment: .leading, spacing: 14) {
                if mcp != nil || onOpenSetup != nil {
                    MCPServerPanel(mcp: mcp, onOpenSetup: onOpenSetup)
                }
                HarnessesPanel(rows: rows)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(AuspexPalette.canvas)
    }
}

/// What the MCP server is doing, and the way into the setup sheet.
///
/// Above the rack rather than below it: the rack answers *what is installed on
/// this machine*, and this answers *can those things talk to Auspex* — which is
/// the question somebody opens this page with once they have read the rack
/// twice.
struct MCPServerPanel: View {
    var mcp: MCPController?
    var onOpenSetup: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                StateDot(color: dotColor, glows: mcp?.status == .listening)
                Text("MCP server")
                    .font(AuspexType.rowStrong)
                    .foregroundStyle(AuspexPalette.text)
                Spacer(minLength: 8)
                if let onOpenSetup {
                    Button("Set up agents…", action: onOpenSetup)
                        .buttonStyle(.auspex)
                        .font(AuspexType.pill)
                        .foregroundStyle(AuspexPalette.stateThinking)
                        .help("Register Auspex with each harness, and install the task-protocol note")
                }
            }
            Text(mcp?.summary ?? "Not running in this process.")
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text2)
                .lineLimit(2)
                .truncationMode(.middle)
                .fixedSize(horizontal: false, vertical: true)
            if let mcp, !mcp.connections.isEmpty {
                // Kernel-reported pids only. No command line and no path: those
                // can carry credentials, and a connection list has no business
                // with either.
                Text(
                    mcp.connections
                        .map { connection in
                            connection.processID.map { "pid \($0)" } ?? "an unattributed client"
                        }
                        .joined(separator: " · ")
                )
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
                .lineLimit(1)
                .truncationMode(.tail)
            }
        }
        .padding(14)
        .frame(maxWidth: 1_180, alignment: .leading)
        .panelChrome()
    }

    private var dotColor: Color {
        switch mcp?.status {
        case .listening: AuspexPalette.stateWriting
        case .conflict: AuspexPalette.statePermission
        case .stopped, .none: AuspexPalette.stateIdle
        }
    }
}

/// The rack, without the scroll view around it — the same split
/// ``BoardEmptyState`` uses, and for the same reason: a panel is composable and
/// a scroll view is not.
struct HarnessesPanel: View {
    let rows: [HarnessStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if rows.isEmpty {
                EmptyStateView(
                    symbol: "square.stack.3d.up.slash",
                    title: "No harness to report on.",
                    detail: "Auspex names a harness here as soon as an adapter watches a "
                        + "store for it."
                )
                .frame(maxWidth: .infinity)
            }
            ForEach(rows) { row in
                HarnessRackRow(status: row)
            }
            footnote
        }
        .frame(maxWidth: 1_180, alignment: .leading)
    }

    /// One sentence, in a dashed box, at the bottom of the rack.
    ///
    /// It is the page's one claim about *behaviour* rather than about state,
    /// and it is the claim a reader most needs: nothing here is written to.
    private var footnote: some View {
        Text(
            "The rack is read-only: Auspex tails each store's own files and never writes "
                + "into a harness directory on its own. The one exception is the setup "
                + "above — registering the MCP server and installing the task-protocol "
                + "note — which happens only when you click it, only inside a fenced "
                + "block, and can be undone from the same place."
        )
        .font(AuspexType.caption)
        .foregroundStyle(AuspexPalette.text3)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(
                AuspexPalette.line,
                style: StrokeStyle(lineWidth: 1, dash: [4, 4])
            )
        )
        .padding(.top, 6)
    }
}

/// One unit in the rack, as one line.
///
/// Six columns, fixed, because the page is read down a column: *which of these
/// is not detected*, *which one is busy*, *which one has been quiet all day*.
/// A row whose fields moved with its content would make every one of those a
/// left-to-right read instead.
private struct HarnessRackRow: View {
    let status: HarnessStatus

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            identity.frame(width: 240, alignment: .leading)
            detection.frame(width: 104, alignment: .leading)
            counters.frame(width: 186, alignment: .leading)
            Text(RelativeTimeText.since(status.lastEventAt))
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
                .frame(width: 96, alignment: .leading)
            servers.frame(maxWidth: .infinity, alignment: .leading)
            hooks.frame(width: 96, alignment: .leading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .panelChrome()
        .accessibilityElement(children: .contain)
    }

    /// The vendor's mark, the harness's full name, and the directory Auspex
    /// actually opens for it.
    private var identity: some View {
        HStack(spacing: 12) {
            HarnessBadge(harness: status.harness, size: 28, isMuted: !status.isDetected)
            VStack(alignment: .leading, spacing: 1) {
                Text(status.harness.displayName)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(AuspexPalette.text)
                    .lineLimit(1)
                Text(status.storePath.map(PathDisplay.abbreviate) ?? "—")
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(2)
                    .truncationMode(.head)
                // Two harnesses read one tree; say so where the path is, or
                // the rack shows the same store twice with no explanation.
                if let note = AuspexAdapters.storeNote(for: status.harness) {
                    Text(note)
                        .font(.system(size: 10.5))
                        .foregroundStyle(AuspexPalette.text3)
                        .lineLimit(1)
                }
            }
        }
        .help(storeHelp)
    }

    private var storeHelp: String {
        let parts = [status.storePath, AuspexAdapters.storeNote(for: status.harness)].compactMap { $0 }
        return parts.isEmpty ? "No adapter watches a store for this harness." : parts.joined(separator: " — ")
    }

    /// Whether the store is on this Mac. A `stat`, and nothing else — kept
    /// visibly apart from the counts so that "no sessions on the board" can
    /// never read as "not installed".
    private var detection: some View {
        HStack(spacing: 6) {
            StateDot(
                color: status.isDetected ? AuspexPalette.stateWriting : AuspexPalette.text3,
                glows: false,
                size: 7
            )
            Text(status.isDetected ? "detected" : "not installed")
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text2)
                .fixedSize()
        }
    }

    /// Live, idle, total — in that order, because a reader scanning this column
    /// is looking for the first one.
    private var counters: some View {
        HStack(spacing: 14) {
            CountBadge(value: status.liveCount, label: "live", tint: AuspexPalette.stateWriting)
            CountBadge(value: status.idleCount, label: "idle", tint: AuspexPalette.text)
            CountBadge(value: status.totalCount, label: "total", tint: AuspexPalette.text)
        }
    }

    /// What this harness has been told it can reach.
    @ViewBuilder
    private var servers: some View {
        if let mcp = status.mcp {
            FlowLayout(spacing: 6, lineSpacing: 6) {
                Text("MCP")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .padding(.vertical, 5)
                ForEach(mcp.serverNames, id: \.self) { name in
                    ServerChip(name: name, isScoped: false)
                }
                ForEach(mcp.scopedServerNames, id: \.self) { name in
                    ServerChip(name: name, isScoped: true)
                }
                AuspexSlot(isRegistered: mcp.registersAuspex)
            }
            .help(summary(mcp))
        } else if let note = HarnessMCPConfigStore.externallyManagedNote(for: status.harness) {
            // No file to name. Saying so is the honest row: pointing at the
            // sibling harness's config would report the wrong servers with
            // full confidence.
            HStack(spacing: 6) {
                Text("MCP")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                Text(note)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
            }
        }
    }

    /// Whether this harness pushes lifecycle events to Auspex rather than
    /// being tailed. Nothing does yet, and an empty ring is how the board says
    /// "expected, not yet real" everywhere else.
    private var hooks: some View {
        HStack(spacing: 6) {
            Circle()
                .strokeBorder(AuspexPalette.text3, lineWidth: 1)
                .frame(width: 7, height: 7)
            Text("hooks off")
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                .fixedSize()
        }
        .help(
            "Harness hooks push a lifecycle event the moment it happens instead of on the "
                + "next file poll. They are opt-in and land in a later milestone; file tailing stays the "
                + "baseline either way."
        )
    }

    /// What the config amounts to, in one phrase.
    private func summary(_ mcp: HarnessMCPConfig) -> String {
        guard mcp.exists else { return "no config file" }
        guard mcp.didParse else { return "could not be read" }
        switch mcp.serverCount {
        case 0: return "no servers"
        case 1: return "1 server"
        default: return "\(mcp.serverCount) servers"
        }
    }
}

// MARK: - Parts

/// One configured MCP server.
///
/// A scoped server — configured for one project directory rather than for the
/// harness — is drawn dimmer and marked, because "this server is available" and
/// "this server is available in one directory" are different facts and a chip
/// that looked the same for both would assert the stronger one.
private struct ServerChip: View {
    let name: String
    let isScoped: Bool

    var body: some View {
        FactChip(tint: nil, isMono: true) {
            HStack(spacing: 3) {
                if isScoped {
                    Image(systemName: "folder")
                        .font(.system(size: 7, weight: .semibold))
                }
                Text(name)
            }
        }
        .opacity(isScoped ? 0.7 : 1)
        .help(isScoped ? "Configured for one project directory" : "Configured for every session")
    }
}

/// The slot Auspex's own MCP server will occupy.
///
/// Drawn as an empty socket rather than left off the page, because the whole
/// point of reading these files is to answer one question — *can the agents on
/// this machine see the task board yet* — and the answer today is no. A dashed
/// outline is the same idiom the board uses for a stale session: present,
/// expected, not yet real.
private struct AuspexSlot: View {
    let isRegistered: Bool

    var body: some View {
        HStack(spacing: 4) {
            if isRegistered {
                Image(systemName: "checkmark.seal.fill")
                    .font(.system(size: 8, weight: .bold))
            }
            Text(
                isRegistered
                    ? HarnessMCPConfigStore.auspexServerName
                    : "\(HarnessMCPConfigStore.auspexServerName) — not registered"
            )
            .font(AuspexType.caption)
            .lineLimit(1)
        }
        .foregroundStyle(isRegistered ? AuspexPalette.stateWriting : AuspexPalette.text3)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(
                (isRegistered ? AuspexPalette.stateWriting : AuspexPalette.line2),
                style: StrokeStyle(lineWidth: 1, dash: isRegistered ? [] : [3, 3])
            )
        )
        .help(
            isRegistered
                ? "This harness can reach the Auspex task board."
                : "This harness cannot reach the Auspex task board. "
                    + "Register it from “Set up agents…” above."
        )
    }
}

/// How long ago something happened, in the shortest form that is still exact
/// enough to act on.
enum RelativeTimeText {
    static func since(_ date: Date?, now: Date = Date()) -> String {
        guard let date else { return "never" }
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<10: return "just now"
        case ..<60: return "\(Int(seconds))s ago"
        case ..<3_600: return "\(Int(seconds / 60))m ago"
        case ..<86_400: return "\(Int(seconds / 3_600))h ago"
        default: return "\(Int(seconds / 86_400))d ago"
        }
    }
}
