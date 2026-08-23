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
    /// The units the wall derived, for the three numbers about the task board.
    /// Empty in a preview and in the offscreen renderer, which draws the row
    /// without them.
    var units: [TaskUnit] = []
    /// The MCP listener, when there is one. `nil` in a render with no app
    /// behind it.
    var mcp: MCPController?
    /// Opens the setup sheet. `nil` where there is nowhere to present one.
    var onOpenSetup: (() -> Void)?

    var body: some View {
        HarnessesPage(
            rows: model.rows(board: board, units: units),
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
                        .help(
                            "Register Auspex with each harness, install the short protocol note, "
                                + "and add the optional coordination skill"
                        )
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
                + "above — registering MCP, installing the short note or versioned skill, "
                + "and hooks. It happens only when you click. Config edits stay fenced; "
                + "the skill has one hashed, Auspex-owned directory and modified content "
                + "is never overwritten or removed."
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
///
/// ## Three zones, and why the row has to have them
///
/// The columns are grouped into *identity*, *status* — detection, the counts,
/// the last event — and *reach*, which is the MCP configuration and the hook
/// state. The grouping is what the row stacks along when it will not fit on
/// one line, and the six columns keep their widths inside it.
///
/// It is a fix rather than a refinement. The reach zone used to declare an
/// ideal width of zero so that the ladder chose on the fixed columns alone,
/// which meant the one-line layout was picked at any width past about 800
/// points — and then handed the chips whatever few points were left over.
/// A ``FlowLayout`` given six points puts every chip on a line of its own and
/// draws each one at the width it asked for, so eight MCP servers became eight
/// lines running out over "hooks off". Now the zone declares the width it
/// actually needs, so the row stacks *before* it is squeezed rather than
/// overflowing after.
private struct HarnessRackRow: View {
    let status: HarnessStatus
    /// The instant the countdown on the quota line is measured against.
    ///
    /// Set when the row is built, which is once per board frame — the same
    /// cadence `RelativeTimeText.since` runs at on the column beside it. A
    /// clock of its own would be a ticking view on a page nobody watches for
    /// seconds.
    private let now = Date()

    /// The three zones, when there is room for three zones.
    ///
    /// `reach` is wrapped rather than framed directly: `servers` draws nothing
    /// for a harness whose MCP config Auspex cannot name, and a
    /// `frame(maxWidth: .infinity)` on an `EmptyView` contributes no layout at
    /// all — so those rows shrank to their content and put "hooks off" a
    /// hundred points left of every other row's. A `Spacer` is a real view and
    /// always fills.
    private var wide: some View {
        HStack(alignment: .center, spacing: Self.zoneSpacing) {
            identity.frame(width: Self.identityWidth, alignment: .leading)
            statusZone
            reachZone
        }
    }

    /// The same facts on two lines, for a column too narrow for three zones.
    ///
    /// The zones stack whole: identity and the status columns — which are what
    /// the page is scanned down — keep the first line, and the configuration
    /// with the hook state goes under them, where the chips get the row's whole
    /// width to wrap in instead of the remainder of somebody else's.
    private var narrow: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: Self.zoneSpacing) {
                identity.frame(maxWidth: .infinity, alignment: .leading)
                statusZone.fixedSize()
            }
            reachZone
        }
    }

    /// Detection, the counts, what this harness has been doing on the task
    /// board, and how long ago it last did anything.
    private var statusZone: some View {
        HStack(alignment: .center, spacing: Self.columnSpacing) {
            detection.frame(width: Self.detectionWidth, alignment: .leading)
            counters.frame(width: Self.countersWidth, alignment: .leading)
            // Fixed even when it is empty, which it is for every harness
            // nobody has adopted the task protocol on: a column that
            // disappeared on eight rows and appeared on the ninth would put
            // every column after it in a different place on that row.
            work.frame(width: Self.workWidth, alignment: .leading)
            lastEvent.frame(width: Self.lastEventWidth, alignment: .leading)
        }
    }

    /// What this harness can reach, and whether it pushes events back.
    ///
    /// `.top` rather than `.center`: the chips wrap to two lines on a narrow
    /// row and a centred "hooks off" would drift down the row with them.
    private var reachZone: some View {
        HStack(alignment: .top, spacing: Self.columnSpacing) {
            HStack(spacing: 0) {
                servers
                Spacer(minLength: 0)
            }
            // A real ideal width, which is the whole fix: it is what the
            // ladder above measures, so the one-line layout is offered only
            // where the chips have somewhere to go. Zero where this harness
            // has no configuration to show — a row with nothing in the column
            // does not need width for it, and stacking one of eight rows for a
            // column that is empty looks like a bug in the row.
            .frame(
                idealWidth: hasReach ? Self.serversWidth : 0,
                maxWidth: .infinity,
                alignment: .leading
            )
            hooks.frame(width: Self.hooksWidth, alignment: .trailing)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                wide
                narrow
            }
            // Under the row rather than in it: the six columns above are all
            // fixed-width and fully committed, and a seventh would squeeze
            // "resets in 2 h 10 m" into three characters. A full-width second
            // line also survives the narrow layout without a second edit.
            quotaLine
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .panelChrome()
        .accessibilityElement(children: .contain)
    }

    /// What the harness itself said about its plan window, when it said
    /// anything.
    ///
    /// Codex only, today, and read off its rollout — no network call, and no
    /// claim about anybody's account beyond what a session already wrote down.
    /// Absent rather than "unknown" for the other eight: a row that said
    /// "limit unknown" on every harness would be eight lines of nothing.
    @ViewBuilder
    private var quotaLine: some View {
        if let quota = status.quota {
            Text(quota.label(now: now))
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.text3)
                .lineLimit(1)
                .truncationMode(.tail)
                .help(quota.helpText(now: now))
        }
    }

    /// Wide enough for "hooks off" and its ring, so the chip is in the same
    /// place on every row whatever is to its left.
    private static let hooksWidth: CGFloat = 88
    /// The mark, the longest harness name, and a store path under it.
    private static let identityWidth: CGFloat = 220
    /// "not installed", which is longer than "detected".
    private static let detectionWidth: CGFloat = 100
    /// Three counts of up to three digits each.
    private static let countersWidth: CGFloat = 160
    /// Two counts and a median duration, when the harness has claimed
    /// anything.
    private static let workWidth: CGFloat = 176
    /// "just now" and "137d ago" both fit.
    private static let lastEventWidth: CGFloat = 86
    /// The narrowest the MCP zone is any use at: the word, and the widest
    /// single chip it can hold — `auspex — not registered`, which is the one
    /// that has to fit or it would hang out over the hook state.
    ///
    /// It is the number that decides where the row stacks. Identity, status —
    /// which carries the task-board column too — this, the gaps and the row's
    /// own padding come to about 1,100 points, so the rack is one line per
    /// harness in a wide window and two in a 1,280 pt one, where the board's
    /// column is 1,007 points.
    private static let serversWidth: CGFloat = 168
    /// The air between two zones, and between two columns inside one.
    private static let zoneSpacing: CGFloat = 16
    private static let columnSpacing: CGFloat = 12

    /// Whether this row has anything at all to say about MCP.
    private var hasReach: Bool {
        status.mcp != nil
            || HarnessMCPConfigStore.externallyManagedNote(for: status.harness) != nil
    }

    private var lastEvent: some View {
        Text(RelativeTimeText.since(status.lastEventAt))
            .font(AuspexType.monoSmall)
            .foregroundStyle(AuspexPalette.text3)
            .lineLimit(1)
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
                // Middle truncation, on one line. A store path is
                // `~/.something/sessions`: the two ends are what identify it
                // and the middle is what a 240 pt column cannot hold, so
                // cutting the head threw away the half that says which harness
                // this is. Where no adapter has told us a root yet, the store
                // the adapter *would* watch is named instead of an em dash —
                // it is a constant in this source, not something read off the
                // machine.
                Text(storeLine)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
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

    private var storeLine: String {
        status.storePath.map(PathDisplay.abbreviate)
            ?? AuspexAdapters.storeDescription(for: status.harness)
    }

    private var storeHelp: String {
        let parts = [
            status.storePath ?? AuspexAdapters.storeDescription(for: status.harness),
            AuspexAdapters.storeNote(for: status.harness)
        ].compactMap { $0 }
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
        HStack(spacing: 12) {
            CountBadge(value: status.liveCount, label: "live", tint: AuspexPalette.stateWriting)
            CountBadge(value: status.idleCount, label: "idle", tint: AuspexPalette.text)
            CountBadge(value: status.totalCount, label: "total", tint: AuspexPalette.text)
        }
    }

    /// What this harness has been doing on the task board.
    ///
    /// A different question from the counters above, and the one somebody asks
    /// when they are choosing where to send the next job: how much is it
    /// holding, how much has it finished, and how long does that take it.
    /// Absent entirely for a harness that has never claimed anything, which is
    /// every harness until somebody adopts the task protocol.
    @ViewBuilder
    private var work: some View {
        if !status.work.isEmpty {
            HStack(spacing: 14) {
                CountBadge(
                    value: status.work.claimed,
                    label: "claimed",
                    tint: AuspexPalette.stateTool
                )
                CountBadge(
                    value: status.work.closed,
                    label: "finished",
                    tint: AuspexPalette.stateWriting
                )
                if let median = status.work.medianSeconds {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(DurationText.compact(median))
                            .font(AuspexType.monoCount)
                            .auspexTabularDigits()
                            .foregroundStyle(AuspexPalette.text)
                        Text("median")
                            .auspexLabel(AuspexType.labelSmall)
                            .foregroundStyle(AuspexPalette.text3)
                    }
                    .fixedSize()
                    .help("Median time from claim to finish, over the tasks this harness closed")
                }
            }
        }
    }

    /// What this harness has been told it can reach.
    ///
    /// Capped at ``RackChips/limit`` names with a `+N` after them. A machine
    /// with two dozen MCP servers configured turns an eight-row rack into a
    /// page, and the question this column answers — *can this harness reach
    /// the board, and roughly what else* — is answered by the first six and
    /// the number.
    @ViewBuilder
    private var servers: some View {
        if let mcp = status.mcp {
            let chips = RackChips(config: mcp)
            FlowLayout(spacing: 6, lineSpacing: 6) {
                Text("MCP")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .padding(.vertical, 5)
                ForEach(chips.shown, id: \.self) { chip in
                    ServerChip(name: chip.name, isScoped: chip.isScoped)
                }
                if chips.hidden > 0 {
                    FactChip("+\(chips.hidden)")
                        .help(chips.hiddenHelp)
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
                    .lineLimit(1)
                    .truncationMode(.tail)
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

/// Which MCP servers a rack row draws, and how many it did not.
///
/// A value rather than a `ForEach` over two arrays, because the cap has to be
/// applied to the two of them *together*: a harness with five global servers
/// and five project-scoped ones must not draw ten chips because neither list
/// on its own reached the limit.
///
/// Names are shortened here rather than by `truncationMode`, so the shortening
/// is a property of the row that can be asserted rather than a function of how
/// much space one chip happened to be given.
struct RackChips {
    /// One chip: the name as it will be drawn, and whether it is scoped.
    struct Chip: Hashable {
        let name: String
        let isScoped: Bool
    }

    /// How many names are drawn before the rest become a number.
    ///
    /// Six is two lines of chips at the width the column has in a normal
    /// window, which is as much as a status row can spend on a list nobody
    /// came to this page to read in full.
    static let limit = 6
    /// How long a server name may be before its middle is taken out.
    static let nameLimit = 18

    let shown: [Chip]
    let hidden: Int
    /// The full names of the ones that were not drawn, for the tooltip.
    private let hiddenNames: [String]

    init(config: HarnessMCPConfig) {
        self.init(names: config.serverNames, scoped: config.scopedServerNames)
    }

    init(names: [String], scoped: [String]) {
        // Global first: "this server is available" outranks "this server is
        // available in one directory", and a cap that dropped the stronger
        // fact to keep the weaker one would misreport the harness.
        let all = names.map { Chip(name: $0, isScoped: false) }
            + scoped.map { Chip(name: $0, isScoped: true) }
        shown = all.prefix(Self.limit).map {
            Chip(name: Self.shorten($0.name), isScoped: $0.isScoped)
        }
        hiddenNames = all.dropFirst(Self.limit).map(\.name)
        hidden = hiddenNames.count
    }

    /// What the `+N` chip says when it is pointed at.
    var hiddenHelp: String {
        "Also configured: " + hiddenNames.joined(separator: ", ")
    }

    /// A server name with its middle taken out.
    ///
    /// The middle, because the two ends are what tell `cloudflare-docs` from
    /// `cloudflare-observability` and a name cut at the head reads as a
    /// different server entirely.
    static func shorten(_ name: String, limit: Int = RackChips.nameLimit) -> String {
        guard name.count > limit else { return name }
        let head = (limit - 1) - (limit - 1) / 2
        let tail = (limit - 1) / 2
        return name.prefix(head) + "…" + name.suffix(tail)
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
/// A span of time, in one or two characters and a unit.
///
/// For the numbers that are *durations* rather than *ages* — how long a
/// harness takes to finish a task, most of all. `RelativeTimeText` says "3h
/// ago", which is a different sentence.
enum DurationText {
    static func compact(_ seconds: TimeInterval) -> String {
        let seconds = max(0, seconds)
        switch seconds {
        case ..<60: return "\(Int(seconds))s"
        case ..<3_600: return "\(Int(seconds / 60))m"
        case ..<86_400:
            let hours = seconds / 3_600
            return hours < 10
                ? String(format: "%.1fh", hours)
                : "\(Int(hours))h"
        default:
            let days = seconds / 86_400
            return days < 10 ? String(format: "%.1fd", days) : "\(Int(days))d"
        }
    }
}

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
