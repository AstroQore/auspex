import AgentSessionKit
import AuspexCore
import SwiftUI

/// The Harnesses page: a rack of the seven harnesses Auspex watches, each with
/// a status line and a detail line.
///
/// ## What it is for
///
/// One question, asked from two directions. *Why is this harness not on my
/// board* — which is answered by whether its store exists, whether an adapter
/// reads it, and when it last did anything. And *what can this harness reach* —
/// which is answered by its MCP configuration, and which is the question M3's
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

    var body: some View {
        HarnessesPage(rows: model.rows(board: board))
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

    var body: some View {
        ScrollView {
            HarnessesPanel(rows: rows)
                .padding(24)
                .frame(maxWidth: .infinity)
        }
        .background(BoardSurfaceBackground())
    }
}

/// The panel, without the scroll view around it — the same split
/// ``BoardEmptyState`` uses, and for the same reason: a panel is composable and
/// a scroll view is not.
struct HarnessesPanel: View {
    let rows: [HarnessStatus]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header(rows: rows)
            rack(rows: rows)
            footnote
        }
        .frame(maxWidth: 720, alignment: .leading)
        .panelChrome()
    }

    // MARK: Header

    private func header(rows: [HarnessStatus]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .font(.system(size: 10, weight: .semibold))
                Text("Harnesses").auspexLabel()
            }
            .foregroundStyle(AuspexPalette.stateWriting)

            Text(headline(rows: rows))
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.textPrimary)

            Text(
                "Auspex reads each harness's own session store and its MCP configuration. "
                    + "It never writes to either."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private func headline(rows: [HarnessStatus]) -> String {
        let detected = rows.count(where: \.isDetected)
        let live = rows.reduce(0) { $0 + $1.liveCount }
        let installed = detected == 1 ? "1 harness installed" : "\(detected) harnesses installed"
        guard live > 0 else { return "\(installed), nothing running." }
        return "\(installed), \(live) session\(live == 1 ? "" : "s") running."
    }

    // MARK: Rack

    private func rack(rows: [HarnessStatus]) -> some View {
        VStack(spacing: 0) {
            columnHeader
            ForEach(rows) { row in
                HarnessRackRow(status: row)
                if row.id != rows.last?.id {
                    Divider().overlay(AuspexPalette.hairline)
                }
            }
        }
        .background(AuspexPalette.well)
        .overlay(Rectangle().strokeBorder(AuspexPalette.hairline, lineWidth: 1))
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text("Harness").auspexLabel(AuspexType.labelSmall).frame(width: 132, alignment: .leading)
            Text("Sessions").auspexLabel(AuspexType.labelSmall)
            Spacer(minLength: 8)
            Text("Last activity").auspexLabel(AuspexType.labelSmall)
            Text("Store").auspexLabel(AuspexType.labelSmall).frame(width: 168, alignment: .trailing)
        }
        .foregroundStyle(AuspexPalette.textTertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.hairline).frame(height: 1)
        }
    }

    private var footnote: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Hooks")
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
            Text(
                "Harness hooks push a lifecycle event to Auspex the moment it happens, "
                    + "instead of on the next file poll. They are opt-in and land in M3; "
                    + "file tailing stays the baseline either way."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
    }
}

/// One unit in the rack: a status line, and the configuration under it.
private struct HarnessRackRow: View {
    let status: HarnessStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            statusLine
            configLine
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .accessibilityElement(children: .contain)
    }

    // MARK: Status

    private var statusLine: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                HarnessBadge(harness: status.harness, size: 20, isMuted: !status.isDetected)
                VStack(alignment: .leading, spacing: 1) {
                    Text(status.harness.displayName)
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.textPrimary)
                        .lineLimit(1)
                    DetectionTag(isDetected: status.isDetected)
                }
            }
            .frame(width: 132, alignment: .leading)

            counters

            Spacer(minLength: 8)

            Text(RelativeTimeText.since(status.lastEventAt))
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.textSecondary)
                .fixedSize()

            VStack(alignment: .trailing, spacing: 1) {
                Text(status.storePath.map(PathDisplay.abbreviate) ?? "—")
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.head)
                // Two rows naming one directory looks like a bug until it is
                // explained, and one line of explanation is cheaper than a
                // person discovering it from a duplicate path.
                if let note = AuspexAdapters.storeNote(for: status.harness) {
                    Text(note)
                        .font(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.textTertiary)
                        .lineLimit(2)
                        .multilineTextAlignment(.trailing)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(width: 168, alignment: .trailing)
            .help(status.storePath ?? "No adapter watches a store for this harness.")
        }
    }

    /// Live, idle, total — in that order, because a reader scanning this column
    /// is looking for the first one.
    private var counters: some View {
        HStack(spacing: 9) {
            CountBadge(value: status.liveCount, label: "live", tint: AuspexPalette.stateWriting)
            CountBadge(value: status.idleCount, label: "idle", tint: AuspexPalette.textSecondary)
            CountBadge(value: status.totalCount, label: "total", tint: AuspexPalette.textSecondary)
        }
    }

    // MARK: MCP

    @ViewBuilder
    private var configLine: some View {
        if let mcp = status.mcp {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text("MCP")
                        .auspexLabel(AuspexType.labelSmall)
                        .foregroundStyle(AuspexPalette.textTertiary)
                    Text(PathDisplay.abbreviate(mcp.location.path))
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.head)
                    Spacer(minLength: 6)
                    Text(summary(mcp))
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.textSecondary)
                        .fixedSize()
                }
                serverChips(mcp)
            }
            .padding(.leading, 27)
        } else if let note = HarnessMCPConfigStore.externallyManagedNote(for: status.harness) {
            // No file to name. Saying so is the honest row: pointing at the
            // sibling harness's config would report the wrong servers with
            // full confidence.
            HStack(spacing: 6) {
                Text("MCP")
                    .auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.textTertiary)
                Text(note)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.textTertiary)
                Spacer(minLength: 6)
            }
            .padding(.leading, 27)
        }
    }

    @ViewBuilder
    private func serverChips(_ mcp: HarnessMCPConfig) -> some View {
        let columns = [GridItem(.adaptive(minimum: 104, maximum: 220), spacing: 5, alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 5) {
            ForEach(mcp.serverNames, id: \.self) { name in
                ServerChip(name: name, isScoped: false)
            }
            ForEach(mcp.scopedServerNames, id: \.self) { name in
                ServerChip(name: name, isScoped: true)
            }
            AuspexSlot(isRegistered: mcp.registersAuspex)
        }
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

/// Whether the harness's store is on this Mac.
private struct DetectionTag: View {
    let isDetected: Bool

    var body: some View {
        Text(isDetected ? "Detected" : "Not installed")
            .auspexLabel(AuspexType.labelSmall)
            .foregroundStyle(isDetected ? AuspexPalette.stateWriting : AuspexPalette.textTertiary)
    }
}

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
        HStack(spacing: 3) {
            if isScoped {
                Image(systemName: "folder")
                    .font(.system(size: 7, weight: .semibold))
            }
            Text(name)
                .font(AuspexType.monoSmall)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .foregroundStyle(isScoped ? AuspexPalette.textTertiary : AuspexPalette.textSecondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(Capsule().strokeBorder(AuspexPalette.hairline, lineWidth: 1))
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
        HStack(spacing: 3) {
            Image(systemName: isRegistered ? "checkmark.seal.fill" : "circle.dashed")
                .font(.system(size: 8, weight: .bold))
            Text(HarnessMCPConfigStore.auspexServerName)
                .font(AuspexType.monoSmall)
            if !isRegistered {
                Text("M3").auspexLabel(AuspexType.labelSmall)
            }
        }
        .foregroundStyle(isRegistered ? AuspexPalette.stateWriting : AuspexPalette.textTertiary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .overlay(
            Capsule().strokeBorder(
                (isRegistered ? AuspexPalette.stateWriting : AuspexPalette.textTertiary)
                    .opacity(0.5),
                style: StrokeStyle(lineWidth: 1, dash: isRegistered ? [] : [2.5, 2.5])
            )
        )
        .help(
            isRegistered
                ? "This harness can reach the Auspex task board."
                : "Auspex has no MCP server to register yet. It arrives in M3."
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
