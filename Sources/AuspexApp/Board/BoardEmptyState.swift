import AgentSessionKit
import AuspexCore
import SwiftUI

/// What the board shows when there is nothing on it.
///
/// An empty screen is an invitation to act, so this one is a status panel
/// rather than an apology: it names every store Auspex is interested in,
/// says plainly whether an adapter exists to read it yet, and offers the one
/// thing a person can do right now — run the demo board.
///
/// It is also the only place the ingest pipeline's notices are visible, which
/// is deliberate: a notice about an unreadable directory matters exactly when
/// the board is empty and a person is wondering why.
struct BoardEmptyState: View {
    let model: LiveBoardModel

    var body: some View {
        ScrollView {
            BoardEmptyStateContent(model: model)
                .frame(maxWidth: 640, alignment: .leading)
                .panelChrome()
                .padding(24)
                .frame(maxWidth: .infinity)
        }
    }
}

/// The panel itself, without the scroll view around it.
struct BoardEmptyStateContent: View {
    let model: LiveBoardModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            watchList
            if !model.diagnostics.isEmpty { noticeList }
            footer
        }
    }

    // MARK: Sections

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.Board.Empty.watching)
                    .auspexLabel()
            }
            .foregroundStyle(AuspexPalette.stateThinking)

            Text(headline)
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.textPrimary)

            Text(explanation)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    private var watchList: some View {
        VStack(spacing: 0) {
            columnHeader
            ForEach(AuspexAdapters.featured, id: \.self) { harness in
                WatchRow(harness: harness, isInstalled: AuspexAdapters.installed.contains(harness))
                if harness != AuspexAdapters.featured.last {
                    Divider().overlay(AuspexPalette.hairline)
                }
            }
        }
        .background(AuspexPalette.well)
        .overlay(Rectangle().strokeBorder(AuspexPalette.hairline, lineWidth: 1))
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Text(L10n.Common.harness).auspexLabel(AuspexType.labelSmall).frame(width: 128, alignment: .leading)
            Text(L10n.Board.Empty.sessionStore).auspexLabel(AuspexType.labelSmall)
            Spacer()
            Text(L10n.Common.status).auspexLabel(AuspexType.labelSmall)
        }
        .foregroundStyle(AuspexPalette.textTertiary)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.hairline).frame(height: 1)
        }
    }

    private var noticeList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.Board.Empty.fromPipeline)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
            ForEach(Array(model.diagnostics.suffix(6).enumerated()), id: \.offset) { _, notice in
                Text(notice)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 16)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.Board.Empty.demoHint)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(AuspexPalette.textTertiary)
            Text("Auspex.app/Contents/MacOS/Auspex --demo")
                .font(AuspexType.mono)
                .foregroundStyle(AuspexPalette.stateWriting)
                .textSelection(.enabled)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(AuspexPalette.well)
                .overlay(Rectangle().strokeBorder(AuspexPalette.hairline, lineWidth: 1))
            Text(L10n.Board.Empty.demoNote)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.textTertiary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(20)
    }

    // MARK: Copy

    private var headline: String {
        model.hasEverSeenSession ? L10n.Board.Empty.allEnded : L10n.Board.Empty.noAgent
    }

    private var explanation: String {
        if AuspexAdapters.installed.isEmpty {
            return L10n.Board.Empty.noAdapter
        }
        return L10n.Board.Empty.tailing
    }
}

/// One line of the watch list.
private struct WatchRow: View {
    let harness: Harness
    let isInstalled: Bool

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                // The accent stays even while the adapter is missing: a harness
                // is the same harness whether or not Auspex can read it yet, and
                // the status chip is what says which.
                HarnessBadge(harness: harness, size: 18)
                Text(harness.displayName)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.textPrimary)
                    .lineLimit(1)
            }
            .frame(width: 128, alignment: .leading)

            Text(AuspexAdapters.storeDescription(for: harness))
                .font(AuspexType.monoSmall)
                .foregroundStyle(AuspexPalette.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 8)

            Text(isInstalled ? L10n.Board.Empty.tailingStatus : L10n.Board.Empty.adapterPending)
                .auspexLabel(AuspexType.labelSmall)
                .foregroundStyle(isInstalled ? AuspexPalette.stateWriting : AuspexPalette.textTertiary)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .overlay(
                    Capsule().strokeBorder(
                        (isInstalled ? AuspexPalette.stateWriting : AuspexPalette.textTertiary)
                            .opacity(0.4),
                        lineWidth: 1
                    )
                )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}
