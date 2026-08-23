import AgentSessionKit
import AgentSessionLive
import AuspexCore
import Foundation
import Observation
import SwiftUI

/// On-demand state for the one task detail currently on screen.
///
/// Nothing instantiates this in the board model or frame assembler. Opening a
/// detail asks once; Refresh asks again; leaving the detail releases it. That
/// boundary is what keeps six small Git processes out of Auspex's idle budget.
@MainActor
@Observable
final class TaskDeliveryModel {
    enum State: Sendable, Equatable {
        case idle
        case loading
        case loaded(DeliverySnapshot)
    }

    private(set) var state: State = .idle
    private var requestKey: String?
    @ObservationIgnored private let reader: GitDeliveryReader

    init(reader: GitDeliveryReader = GitDeliveryReader()) {
        self.reader = reader
    }

    var snapshot: DeliverySnapshot? {
        if case let .loaded(snapshot) = state { return snapshot }
        return nil
    }

    func load(unit: TaskUnit, board: LiveBoardModel, force: Bool = false) async {
        let path = Self.checkoutPath(for: unit, board: board)
        let nextKey = "\(unit.id)\u{0}\(path ?? "")"
        guard force || requestKey != nextKey else { return }
        requestKey = nextKey
        guard let path else {
            state = .loaded(.unknown(
                reason: "No local checkout was recorded for any session on this task."
            ))
            return
        }

        state = .loading
        let reader = reader
        let snapshot = await Task.detached(priority: .userInitiated) {
            reader.snapshot(atPath: path)
        }.value
        guard !Task.isCancelled, requestKey == nextKey else { return }
        state = .loaded(snapshot)
    }

    func packet(
        unit: TaskUnit,
        log: [AuspexTaskLogEntry],
        board: LiveBoardModel
    ) -> HandoffPacket {
        HandoffPacket(
            unit: unit,
            log: log,
            delivery: snapshot,
            resumeHints: Self.resumeHints(for: unit, board: board)
        )
    }

    static func checkoutPath(for unit: TaskUnit, board: LiveBoardModel) -> String? {
        // The lead's worktree is the task's best delivery source. A linked
        // reviewer or subagent is a fallback only when the lead recorded no
        // local directory.
        for row in unit.members {
            guard let identity = board.session(for: row.key)?.identity,
                  let path = SessionHandoff.workingDirectory(for: identity),
                  NSString(string: path).isAbsolutePath else { continue }
            return path
        }
        if let project = unit.projectKey, NSString(string: project).isAbsolutePath {
            return project
        }
        return nil
    }

    static func resumeHints(for unit: TaskUnit, board: LiveBoardModel) -> [HandoffPacket.ResumeHint] {
        unit.members.compactMap { row in
            guard let identity = board.session(for: row.key)?.identity else { return nil }
            let label = "\(row.harness.displayName) \(row.shortID)"
            switch SessionHandoff.resume(for: identity) {
            case let .available(_, shellLine):
                return .init(sessionLabel: label, command: shellLine)
            case let .unavailable(reason):
                return .init(sessionLabel: label, unavailableReason: reason)
            }
        }
    }
}

/// The Delivery axis: observed local Git, separate from the worker's report.
struct TaskDeliverySection: View {
    let unit: TaskUnit
    let board: LiveBoardModel
    var model: TaskDeliveryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Delivery")
                    .auspexLabel(AuspexType.labelLarge)
                    .foregroundStyle(AuspexPalette.text3)
                Text("observed local Git")
                    .font(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.stateThinking)
                Spacer(minLength: 0)
                Button {
                    Task { await model.load(unit: unit, board: board, force: true) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                }
                .buttonStyle(.auspex)
                .disabled(model.state == .loading)
                .help("Read this checkout again. No fetch or network request is made.")
            }

            Group {
                switch model.state {
                case .idle, .loading:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Reading the recorded checkout…")
                            .font(AuspexType.body)
                            .foregroundStyle(AuspexPalette.text3)
                    }
                    .padding(12)
                case .loaded(let snapshot):
                    snapshotView(snapshot)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .panelChrome()
        }
    }

    private func snapshotView(_ snapshot: DeliverySnapshot) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            deliveryProperty("Working tree", snapshot.workingTree.rawValue, tint: stateTint(snapshot))
            if let branch = snapshot.branch { deliveryProperty("Branch", branch, mono: true) }
            if let path = snapshot.repositoryPath { deliveryProperty("Checkout", path, mono: true) }
            if let count = snapshot.changedFileCount {
                let suffix = snapshot.changedFilesTruncated ? "+ shown with a cap" : ""
                deliveryProperty("Changed", "\(count) file\(count == 1 ? "" : "s") \(suffix)")
            }
            if let stat = snapshot.diffstat { deliveryProperty("Diffstat", stat) }
            if let commit = snapshot.lastCommit {
                deliveryProperty("Last commit", "\(commit.shortHash) · \(commit.subject)", mono: true)
            }
            if snapshot.ahead != nil || snapshot.behind != nil {
                deliveryProperty(
                    "Upstream",
                    "ahead \(snapshot.ahead ?? 0) · behind \(snapshot.behind ?? 0) · local refs only"
                )
            }
            if let diagnostic = snapshot.diagnostic {
                deliveryProperty("Observation", diagnostic, tint: AuspexPalette.stateStale)
            }
            if !snapshot.changedFiles.isEmpty {
                Divider().overlay(AuspexPalette.line)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(snapshot.changedFiles.enumerated()), id: \.offset) { _, file in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(file.status)
                                .font(AuspexType.monoSmall)
                                .foregroundStyle(AuspexPalette.stateStale)
                                .frame(width: 20, alignment: .leading)
                            Text(file.path)
                                .font(AuspexType.monoSmall)
                                .foregroundStyle(AuspexPalette.text2)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                }
                .padding(12)
            }
            HStack {
                Spacer()
                Text("checked \(RelativeTimeText.since(snapshot.checkedAt)) · no fetch")
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
        }
    }

    private func deliveryProperty(
        _ key: String,
        _ value: String,
        mono: Bool = false,
        tint: Color = AuspexPalette.text2
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(key)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                .frame(width: 86, alignment: .leading)
            Text(value)
                .font(mono ? AuspexType.monoSmall : AuspexType.body)
                .foregroundStyle(tint)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func stateTint(_ snapshot: DeliverySnapshot) -> Color {
        switch snapshot.workingTree {
        case .clean: AuspexPalette.stateWriting
        case .dirty: AuspexPalette.stateStale
        case .unknown: AuspexPalette.text3
        }
    }
}

/// The task record a reviewer scans beside local delivery state.
struct TaskReviewRecordSection: View {
    let log: [AuspexTaskLogEntry]

    private var dossier: TaskReviewDossier { TaskReviewDossier(log: log) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Review record")
                .auspexLabel(AuspexType.labelLarge)
                .foregroundStyle(AuspexPalette.text3)
            VStack(alignment: .leading, spacing: 12) {
                bucket(
                    "Verification evidence",
                    entries: dossier.evidence,
                    empty: "No verification evidence has been recorded."
                )
                if !dossier.decisions.isEmpty {
                    Divider().overlay(AuspexPalette.line)
                    bucket("Decisions", entries: dossier.decisions, empty: "")
                }
                Divider().overlay(AuspexPalette.line)
                bucket(
                    "Risks",
                    entries: dossier.risks,
                    empty: "No risk note has been recorded; that is not proof of no risk."
                )
            }
            .padding(12)
            .panelChrome()
        }
    }

    private func bucket(
        _ title: String,
        entries: [TaskReviewDossier.Entry],
        empty: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.text3)
            if entries.isEmpty {
                Text(empty)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text3)
            } else {
                ForEach(entries.suffix(8)) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.message)
                            .font(AuspexType.body)
                            .foregroundStyle(AuspexPalette.text2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let ref = entry.ref, !ref.isEmpty {
                            Text(ref)
                                .font(AuspexType.monoSmall)
                                .foregroundStyle(AuspexPalette.stateThinking)
                                .textSelection(.enabled)
                        }
                    }
                }
            }
        }
    }
}

struct TaskHandoffSection: View {
    let unit: TaskUnit
    let board: LiveBoardModel
    let log: [AuspexTaskLogEntry]
    var delivery: TaskDeliveryModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Handoff")
                .auspexLabel(AuspexType.labelLarge)
                .foregroundStyle(AuspexPalette.text3)
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Copy a bounded context packet")
                        .font(AuspexType.body)
                        .foregroundStyle(AuspexPalette.text2)
                    Text("Goal, phase, current state, team, delivery, record, and resume hints. Nothing is sent.")
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                }
                Spacer(minLength: 8)
                Button {
                    let packet = delivery.packet(unit: unit, log: log, board: board)
                    CopyToast.copy(packet.text, what: "the handoff packet")
                } label: {
                    Label("Copy packet", systemImage: "doc.on.doc")
                        .font(AuspexType.caption)
                }
                .buttonStyle(.auspex(cornerRadius: 7))
                .disabled(delivery.snapshot == nil)
                .help(
                    delivery.snapshot == nil
                        ? "Wait for the local delivery check to finish"
                        : "Copy the packet. Nothing is sent."
                )
            }
            .padding(12)
            .panelChrome()
        }
    }
}
