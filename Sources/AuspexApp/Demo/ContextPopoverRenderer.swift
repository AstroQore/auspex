import AgentSessionLive
import AppKit
import AuspexCore
import SwiftUI

/// Renders the context popover to a PNG, offscreen, from the demo board.
///
/// A renderer of its own because `ImageRenderer` has no window and therefore
/// no popover: `--render-board` draws the header's control and can never draw
/// what is behind it. So the popover's body is rendered detached, which is the
/// only way to look at the one panel in the app whose whole job is to be read
/// carefully.
///
/// It runs the real demo pipeline rather than fabricating a composition —
/// in-memory store, real ingest, and `SessionRepository.contextTextVolume`
/// against the bodies the demo actually indexed. A picture of an estimate that
/// skipped the query proves nothing about the query.
@MainActor
enum ContextPopoverRenderer {
    /// The popover's own width, plus a margin so the PNG is not flush to the
    /// panel's edge.
    static let defaultSize = CGSize(width: 360, height: 560)

    static func render(
        to url: URL,
        warmup: TimeInterval = 20,
        size: CGSize = defaultSize,
        scale: CGFloat = 2,
        appearance: AppearanceMode = .dark
    ) throws -> String {
        NSApplication.shared.setActivationPolicy(.prohibited)

        let environment = AppEnvironment(mode: .demo, offersSignalTarget: false)
        environment.board.autoSelectsFirstSession = true
        environment.start()
        defer { Task { await environment.shutdown() } }

        pump(for: warmup)

        let board = environment.board
        guard let chosen = pickSession(in: board) else { throw RenderError.noReading }
        board.selectedKey = chosen
        pump(for: 0.4)
        board.loadContextComposition()
        pumpUntilEstimated(board)

        guard let session = board.selectedSession,
              let gauge = ContextGauge(
                  usage: session.contextUsage, compactions: session.compactions
              )
        else { throw RenderError.noReading }

        let renderer = ImageRenderer(
            content: ContextPopoverSnapshot(
                gauge: gauge,
                tokensOut: session.tokensOut,
                composition: board.contextComposition,
                size: size,
                appearance: appearance
            )
        )
        renderer.scale = scale
        renderer.isOpaque = true
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let representation = NSBitmapImageRep(data: tiff),
              let png = representation.representation(using: .png, properties: [:])
        else { throw RenderError.renderFailed }
        try png.write(to: url)
        return summary(gauge: gauge, composition: board.contextComposition, key: chosen)
    }

    /// The session with a reading and the most indexed prose behind it.
    ///
    /// A derived gauge is preferred, because that is the case with something
    /// to hedge: a measured one has no "window looked up from the model" line
    /// to show, and a screenshot of the panel without it is a screenshot of
    /// the half that was never in doubt.
    private static func pickSession(in board: LiveBoardModel) -> SessionKey? {
        let candidates = board.board.sessions.filter { $0.contextUsage != nil }
        guard !candidates.isEmpty else { return nil }
        return candidates
            .sorted { promise(of: $0) > promise(of: $1) }
            .first?
            .key
    }

    private static func promise(of session: SessionSnapshot) -> Int {
        var score = session.turnCount * 100 + session.toolCallCount * 20
        if session.contextUsage?.source == .derived { score += 5_000 }
        if session.compactions > 0 { score += 1_000 }
        return score
    }

    /// The pipeline runs on detached tasks; spinning the main run loop is what
    /// lets them make progress while this call is on the main actor.
    private static func pump(for seconds: TimeInterval) {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
    }

    private static func pumpUntilEstimated(_ board: LiveBoardModel, timeout: TimeInterval = 3) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline, board.contextComposition == nil {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
        }
        pump(for: 0.15)
    }

    /// What the picture holds, for the caller to print.
    private static func summary(
        gauge: ContextGauge,
        composition: ContextComposition?,
        key: SessionKey
    ) -> String {
        var parts = [
            "\(key.harness.displayName) \(key.sessionID.prefix(8))",
            gauge.label,
            gauge.isDerived ? "derived window" : "measured window",
            "\(gauge.compactions) compactions"
        ]
        if let composition {
            parts.append("\(composition.sampledEvents) bodies indexed")
            for slice in composition.slices where slice.kind != .free {
                parts.append("\(slice.title.lowercased()) \(ContextFormat.tokens(slice.tokens))")
            }
        } else {
            parts.append("no composition — nothing indexed")
        }
        return parts.joined(separator: " · ")
    }

    enum RenderError: Error {
        case noReading
        case renderFailed
    }
}

/// The popover's body, detached from the control that opens it, on the canvas
/// it would float over.
private struct ContextPopoverSnapshot: View {
    let gauge: ContextGauge
    let tokensOut: Int
    let composition: ContextComposition?
    let size: CGSize
    var appearance: AppearanceMode = .dark

    var body: some View {
        ContextUsagePopover(gauge: gauge, tokensOut: tokensOut, composition: composition)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(AuspexPalette.line, lineWidth: 1)
            )
            .frame(width: size.width, height: size.height)
            // Inside the scheme, not outside it: the palette is resolved
            // against the environment of the view it is attached to, and a
            // background painted after the override is painted in whatever
            // the host's appearance was.
            .background(AuspexPalette.canvas)
            .environment(\.isSnapshotRender, true)
            .environment(\.colorScheme, appearance == .light ? .light : .dark)
            .tint(AuspexPalette.accent)
    }
}
