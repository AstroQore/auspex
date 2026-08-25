import AppKit
import AuspexCore
import Foundation

/// Renders the real AppKit Map surface against the fabricated demo store.
/// `ImageRenderer` cannot capture an `NSViewRepresentable`; this uses the
/// view's own display pass so the native scroll/document/hosting boundary is
/// what the screenshot proves.
@MainActor
enum MapSnapshotRenderer {
    static let defaultSize = CGSize(width: 1_200, height: 800)

    static func render(
        to url: URL,
        warmup: TimeInterval = 20,
        size: CGSize = defaultSize,
        history: Bool = false,
        appearance: AppearanceMode = .dark
    ) throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let environment = AppEnvironment(mode: .demo, offersSignalTarget: false)
        environment.start()
        environment.board.viewMode = .perch
        defer { Task { await environment.shutdown() } }

        let deadline = Date().addingTimeInterval(warmup)
        while Date() < deadline {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        let mapDeadline = Date().addingTimeInterval(2)
        while Date() < mapDeadline, environment.board.map.cards.isEmpty {
            RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }
        guard !environment.board.map.cards.isEmpty else { throw RenderError.emptyMap }
        if history {
            environment.board.map.enterHistory()
            let historyDeadline = Date().addingTimeInterval(2)
            while Date() < historyDeadline, environment.board.map.playbackMoment == nil {
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.03))
            }
            if environment.board.map.historyCount > 3 {
                environment.board.map.seek(to: environment.board.map.historyCount * 2 / 3)
                RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
            }
        }

        let view = MapCanvasNSView(frame: CGRect(origin: .zero, size: size))
        view.appearance = appearance.nsAppearance
        view.update(
            cards: environment.board.map.cards,
            frames: environment.board.map.projectFrames,
            dependencies: environment.board.map.dependencies,
            selectedNodeID: environment.board.map.cards.first?.id,
            expandedNodeIDs: Set(environment.board.map.cards.prefix(1).map(\.id)),
            isReadOnly: false,
            viewport: environment.board.map.viewport
        )
        view.layoutSubtreeIfNeeded()
        if let first = environment.board.map.projectFrames.first {
            view.center(on: CGPoint(x: first.rect.midX, y: first.rect.midY))
        }
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.1))
        view.displayIfNeeded()

        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            throw RenderError.renderFailed
        }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else {
            throw RenderError.encodingFailed
        }
        try png.write(to: url, options: .atomic)
    }

    enum RenderError: Error {
        case emptyMap
        case renderFailed
        case encodingFailed
    }
}
