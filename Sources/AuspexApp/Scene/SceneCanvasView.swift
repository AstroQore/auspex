import AppKit
import AuspexCore
import QuartzCore
import SpriteKit

/// What the scene needs from whatever is carrying it.
///
/// The office is drawn by SpriteKit and *navigated* by AppKit, and this is the
/// seam. The scene asks for a viewport and is told where the reader actually
/// is; it never touches a clip view, and the canvas never touches a node.
@MainActor
protocol SceneViewportHost: AnyObject {
    /// What the reader is looking at right now, in scene space.
    var viewport: SceneViewport { get }

    /// Moves the canvas there.
    ///
    /// - Parameters:
    ///   - animated: fly rather than jump.
    ///   - framingEverything: whether this viewport is a *fit*, which is what
    ///     decides whether a later window resize keeps framing the building or
    ///     keeps the reader's place.
    func apply(_ viewport: SceneViewport, animated: Bool, framingEverything: Bool)

    /// Tells the canvas how big the building is, in layout space.
    func setWorld(_ rect: CGRect)

    /// Called once per rendered frame, before the scene reads ``viewport``.
    func advance(to time: TimeInterval)
}

/// The office on a real scroll view.
///
/// ## Why the canvas is an `NSScrollView` and the `SKView` is not in it
///
/// Everything a canvas has to do with two fingers — momentum, elastic edges,
/// the scroll-direction preference, and above all a pinch that *moves* the map
/// while it scales it — is behaviour `NSScrollView` has and no hand-rolled
/// gesture handler keeps for long. So the scroll view owns where the reader is:
/// an empty, world-sized document view gives it something to scroll, its
/// magnification is the zoom, and the `SKView` underneath simply draws the
/// rectangle the clip view is showing.
///
/// The `SKView` is deliberately *not* the document view. A document view is
/// scaled by the magnification, so a Metal-backed one would have to keep a
/// drawable the size of the whole building times the zoom. Measured on the
/// layout: forty projects come to 1 704 × 1 282 points, which at 4× on a
/// Retina display is 559 MB of backing store, and the six-hundred-session day
/// this app is built for comes to 4 304 × 3 154 points — 3.5 GB — for a
/// picture that is 900 points wide on screen. Window-sized and camera-driven
/// it costs the window and nothing else, and the pixel art stays exactly as
/// crisp, because the camera scales the *scene* rather than a bitmap of it.
///
/// So the hierarchy is two siblings: the `SKView` fills the frame and draws,
/// and a transparent scroll view sits over it holding the gestures, the
/// scrollers, and — because it is what the pointer actually lands on — the
/// mouse.
@MainActor
final class SceneCanvasView: NSView, SceneViewportHost {
    /// The view that draws the office.
    let skView: OfficeSKView
    /// The office itself.
    let scene: OfficeScene
    /// Where the reader is and how close, as the platform keeps it.
    let scrollView: SceneScrollView

    private let document: SceneDocumentView
    /// The translation between the floor plan, the document, and the camera.
    private var geometry = SceneScrollGeometry()

    /// The camera moving on its own, and when it started.
    private var flight: SceneFlight?
    private var flightStartedAt: TimeInterval = 0
    /// What this view last wrote to the scroll view, so that a difference means
    /// the reader has taken over and a flight should get out of the way.
    private var written: (magnification: CGFloat, origin: CGPoint)?

    /// Whether the canvas is still showing exactly what a fit showed, with
    /// nobody having panned or zoomed since.
    ///
    /// It is what makes a window resize feel native: a map that was framed
    /// stays framed as the window grows, and a map somebody had zoomed into
    /// keeps the zoom they chose and simply shows more of the world.
    private(set) var isFramingEverything = false

    /// Until when the office is worth drawing at the display's rate rather than
    /// at its resting thirty frames a second.
    private var busyUntil: TimeInterval?

    init(scene: OfficeScene, frame: CGRect) {
        self.scene = scene
        self.skView = OfficeSKView(frame: CGRect(origin: .zero, size: frame.size))
        self.document = SceneDocumentView(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        self.scrollView = SceneScrollView(frame: CGRect(origin: .zero, size: frame.size))
        super.init(frame: frame)

        skView.autoresizingMask = [.width, .height]
        skView.presentScene(scene)

        scrollView.autoresizingMask = [.width, .height]
        scrollView.contentView = SceneClipView()
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.contentView.drawsBackground = false
        scrollView.allowsMagnification = true
        scrollView.minMagnification = SceneViewport.minZoom
        scrollView.maxMagnification = SceneViewport.maxZoom
        // A canvas moves in two dimensions at once. The predominant-axis rule
        // is right for a document, which is read down a column, and wrong for a
        // map, where a diagonal flick that comes out purely vertical reads as
        // the view fighting the hand.
        scrollView.usesPredominantAxisScrolling = false
        scrollView.horizontalScrollElasticity = .allowed
        scrollView.verticalScrollElasticity = .allowed
        scrollView.scrollerStyle = .overlay
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerKnobStyle = .light
        scrollView.canvas = self
        document.canvas = self

        addSubview(skView)
        addSubview(scrollView)

        // The end of a pinch, from the platform's own side of it. The gesture's
        // last event says the same thing and usually says it first, but a
        // magnification that ends because the window resigned key or the
        // gesture was taken over sends no such event — and a canvas left
        // between two rungs is pixel art with seams through it until somebody
        // touches it again.
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveMagnifyEnded),
            name: NSScrollView.didEndLiveMagnifyNotification,
            object: scrollView
        )

        scene.host = self
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("SceneCanvasView is not archived") }

    deinit { NotificationCenter.default.removeObserver(self) }

    @objc private func liveMagnifyEnded(_ note: Notification) {
        settleZoom(atWindowPoint: scrollView.lastPinchLocation)
    }

    // MARK: - Being looked at

    /// Recomputes whether the scene should be running, from the window.
    func refreshPaused() { skView.refreshPaused() }

    /// Stops the clock, for the moment SwiftUI takes the view off screen
    /// without taking it away.
    func suspend() { skView.suspend() }

    /// Releases the scene when SwiftUI takes the view away.
    func stop() {
        scene.host = nil
        skView.stop()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // A wider window shows *more office* rather than a bigger one, unless
        // the reader had asked for the whole building, in which case it goes on
        // showing the whole building.
        if isFramingEverything { fit(animated: false) }
    }

    // MARK: - SceneViewportHost

    var viewport: SceneViewport {
        geometry.viewport(
            documentVisible: scrollView.documentVisibleRect,
            magnification: scrollView.magnification
        )
    }

    func apply(_ next: SceneViewport, animated: Bool, framingEverything: Bool) {
        guard !geometry.isEmpty else { return }
        let target = next.clamped()
        if animated, target != viewport {
            begin(SceneFlight(from: viewport, to: target, duration: SceneFlight.travelDuration))
            noteInteraction()
        } else {
            flight = nil
            write(target)
        }
        isFramingEverything = framingEverything
    }

    func setWorld(_ rect: CGRect) {
        let world = rect.width > 0 && rect.height > 0 ? rect : .zero
        guard world != geometry.world else { return }
        let before = viewport
        geometry = SceneScrollGeometry(world: world)
        document.setFrameSize(
            NSSize(
                width: max(1, geometry.documentSize.width),
                height: max(1, geometry.documentSize.height)
            )
        )
        guard !geometry.isEmpty else { return }
        // The building grew or shrank under a reader who is looking somewhere
        // in it: keep them where they were, unless what they asked for was the
        // whole thing.
        if isFramingEverything {
            fit(animated: false)
        } else {
            var kept = before
            kept.content = geometry.contentRect
            write(kept.clamped())
        }
    }

    func advance(to time: TimeInterval) {
        if let busyUntil, time > busyUntil {
            self.busyUntil = nil
            skView.setInteracting(false)
        }
        guard let flight else {
            keepFraming()
            return
        }
        // A gesture that arrives mid-flight wins: the reader is here now, and a
        // camera that kept flying to where they used to be pointed would be the
        // view arguing with them.
        guard isWhereItWasPut else {
            self.flight = nil
            return
        }
        let elapsed = time - flightStartedAt
        write(flight.viewport(after: elapsed))
        if flight.hasLanded(after: elapsed) { self.flight = nil }
    }

    // MARK: - Moving the scroll view

    /// Frames the whole building.
    func fit(animated: Bool) {
        guard !geometry.isEmpty else { return }
        apply(viewport.fitted(), animated: animated, framingEverything: true)
    }

    /// Keeps a framed building framed.
    ///
    /// "Fit" is a state rather than an event: a reader who asked for the whole
    /// office wants the whole office as the window is dragged wider and as
    /// rooms open and close. Checking it on the frame rather than only when a
    /// resize arrives is what stops it depending on whether the clip view had
    /// already been told its new size — the answer is arithmetic, and a frame
    /// that is already framed writes nothing.
    private func keepFraming() {
        guard isFramingEverything, !geometry.isEmpty else { return }
        let current = viewport
        let fitted = current.fitted()
        guard abs(fitted.zoom - current.zoom) > 0.0001
            || abs(fitted.center.x - current.center.x) > 0.5
            || abs(fitted.center.y - current.center.y) > 0.5
        else { return }
        write(fitted)
    }

    /// Stops a flight because the reader has taken over.
    func cancelFlight() {
        flight = nil
        isFramingEverything = false
        noteInteraction()
    }

    /// Moves the window onto the document by a delta in document points — what
    /// a pinch's travel comes to.
    func scrollDocument(by delta: CGVector) {
        guard delta.dx != 0 || delta.dy != 0 else { return }
        let origin = scrollView.contentView.bounds.origin
        scrollView.contentView.setBoundsOrigin(
            NSPoint(x: origin.x + delta.dx, y: origin.y + delta.dy)
        )
        scrollView.reflectScrolledClipView(scrollView.contentView)
        written = nil
    }

    /// Zooms around a point in the window, continuously — the length of a
    /// ⌘-scroll on a trackpad.
    func zoom(to magnification: CGFloat, atWindowPoint point: CGPoint) {
        let target = min(SceneViewport.maxZoom, max(SceneViewport.minZoom, magnification))
        scrollView.setMagnification(target, centeredAt: documentPoint(fromWindow: point))
        written = nil
        isFramingEverything = false
    }

    /// Steps the zoom by whole rungs around a point in the window — a wheel's
    /// ⌘-scroll, which reports notches rather than pixels.
    func step(rungs: Int, atWindowPoint point: CGPoint) {
        guard rungs != 0 else { return }
        zoom(
            to: SceneViewport.rung(rungs, from: scrollView.magnification),
            atWindowPoint: point
        )
    }

    /// The end of a pinch: the zoom lands on a rung so the pixel grid comes
    /// back, around whatever the fingers were over.
    func settleZoom(atWindowPoint point: CGPoint?) {
        guard !geometry.isEmpty else { return }
        let current = viewport
        let anchor = point.map { geometry.scene(fromDocument: documentPoint(fromWindow: $0)) }
        let settled = current.settled(around: anchor)
        guard settled != current else { return }
        begin(
            SceneFlight(
                from: current,
                to: settled,
                // Under Reduce Motion the grid comes back the instant the
                // fingers do, rather than sliding into place.
                duration: scene.reduceMotion ? 0 : SceneFlight.settleDuration
            )
        )
    }

    /// Starts a flight from wherever the scroll view has got to.
    ///
    /// What is where the scroll view is *now* is also what this view last put
    /// there, as far as the flight is concerned: the check that abandons a
    /// flight is asking "has somebody else moved this since", and at the moment
    /// a flight begins the answer has to be no.
    private func begin(_ next: SceneFlight) {
        flight = next
        flightStartedAt = CACurrentMediaTime()
        written = (scrollView.magnification, scrollView.contentView.bounds.origin)
    }

    /// A two-finger double tap: frame the room under the pointer, or pull back
    /// out if it is already framed.
    func smartZoom(atWindowPoint point: CGPoint) {
        cancelFlight()
        scene.smartZoom(atLayoutPoint: layoutPoint(fromWindow: point))
    }

    /// Says that something is happening, so the office is worth drawing at the
    /// display's rate for the moment.
    func noteInteraction() {
        busyUntil = CACurrentMediaTime() + Self.interactionTail
        skView.setInteracting(true)
    }

    /// How long after the last gesture event the office keeps drawing at the
    /// display's rate. Long enough to cover the gaps between the events of one
    /// gesture, short enough that nothing is still paying for it a moment
    /// after the hand has left the glass.
    private static let interactionTail: TimeInterval = 0.4

    // MARK: - The pointer

    /// Where a point in the window is on the floor plan.
    func layoutPoint(fromWindow point: CGPoint) -> CGPoint {
        geometry.layout(fromDocument: documentPoint(fromWindow: point))
    }

    private func documentPoint(fromWindow point: CGPoint) -> CGPoint {
        document.convert(point, from: nil)
    }

    /// A click, from the document view.
    func click(atWindowPoint point: CGPoint, clickCount: Int) {
        cancelFlight()
        scene.click(atLayoutPoint: layoutPoint(fromWindow: point), clickCount: clickCount)
    }

    /// The pointer moving, from the document view. Not acted on here: the scene
    /// takes at most one hover per drawn frame, which is what turns a hundred
    /// mouse-moved events a second into thirty hit tests.
    func hover(atWindowPoint point: CGPoint?) {
        scene.hover(atLayoutPoint: point.map(layoutPoint(fromWindow:)))
    }

    // MARK: - Writing the scroll view

    /// Puts the scroll view exactly where `next` says, and remembers it.
    private func write(_ next: SceneViewport) {
        guard !geometry.isEmpty, next.zoom > 0 else { return }
        scrollView.magnification = next.zoom
        let origin = geometry.documentOrigin(for: next)
        scrollView.contentView.setBoundsOrigin(origin)
        scrollView.reflectScrolledClipView(scrollView.contentView)
        written = (scrollView.magnification, scrollView.contentView.bounds.origin)
    }

    /// Whether the scroll view still holds what this view last put there.
    private var isWhereItWasPut: Bool {
        guard let written else { return false }
        let origin = scrollView.contentView.bounds.origin
        return abs(written.magnification - scrollView.magnification) < 0.0001
            && abs(written.origin.x - origin.x) < 0.5
            && abs(written.origin.y - origin.y) < 0.5
    }
}

/// The scroll view that carries the office.
///
/// Everything it does not override is the point of it: `super.scrollWheel`
/// brings momentum, the elastic edge, and the system's scroll-direction
/// preference, and `super.magnify` brings a live pinch with the platform's own
/// limits. What is overridden is the part a canvas needs and a document does
/// not — a pinch that also carries the map along with the fingers, a zoom on
/// ⌘-scroll, a smart zoom that frames the room under the pointer, and a landing
/// on the crisp zoom ladder when the fingers lift.
final class SceneScrollView: NSScrollView {
    fileprivate weak var canvas: SceneCanvasView?

    /// When a scroll event was last handled, so that a pinch can tell whether
    /// the system is already panning for it.
    private var lastScrollAt: TimeInterval?
    /// Where the point between the fingers was on the previous magnify event.
    private var pinchCentroid: CGPoint?
    /// Where the fingers last were, so that a pinch which ends without a final
    /// event still lands on a rung around the right place.
    private(set) var lastPinchLocation: CGPoint?

    override func scrollWheel(with event: NSEvent) {
        canvas?.cancelFlight()

        // ⌘-scroll is the mouse's way to zoom. A trackpad reports precise
        // deltas and gets a continuous zoom; a wheel reports notches and gets a
        // rung per notch, because half a rung of a wheel is a wheel that feels
        // broken.
        if event.modifierFlags.contains(.command) {
            commandScroll(event)
            return
        }

        lastScrollAt = CACurrentMediaTime()
        super.scrollWheel(with: event)
    }

    private func commandScroll(_ event: NSEvent) {
        guard let canvas else { return }
        let point = event.locationInWindow
        guard event.hasPreciseScrollingDeltas else {
            canvas.step(rungs: SceneGesture.rungs(forWheelDelta: event.scrollingDeltaY),
                        atWindowPoint: point)
            return
        }
        canvas.zoom(
            to: SceneGesture.zoom(
                magnification, magnifiedBy: event.scrollingDeltaY / Self.pointsPerDoubling
            ),
            atWindowPoint: point
        )
        if event.phase.contains(.ended) || event.momentumPhase.contains(.ended) {
            canvas.settleZoom(atWindowPoint: point)
        }
    }

    /// A pinch: the platform's zoom, plus the travel it does not carry.
    ///
    /// `super` scales the content around the point between the fingers, which
    /// is right and is not enough: fingers that also *slide* are asking for the
    /// map to come with them, and an anchored zoom alone leaves it where it
    /// was. So the travel between one event's centroid and the next is applied
    /// as a scroll — unless the system is already sending scroll events for the
    /// same fingers, in which case the scroll view is doing it and doing it
    /// twice would move the map twice as far as the hand did.
    override func magnify(with event: NSEvent) {
        canvas?.cancelFlight()
        super.magnify(with: event)

        let location = event.locationInWindow
        lastPinchLocation = location
        if event.phase.contains(.began) {
            pinchCentroid = location
            return
        }
        if let previous = pinchCentroid, pansItself {
            canvas?.scrollDocument(
                by: SceneGesture.pinchScroll(
                    centroidDelta: CGVector(
                        dx: location.x - previous.x, dy: location.y - previous.y
                    ),
                    magnification: magnification
                )
            )
        }
        pinchCentroid = location

        if event.phase.contains(.ended) || event.phase.contains(.cancelled) {
            // The pixel grid comes back when the fingers lift, not while they
            // are still moving.
            canvas?.settleZoom(atWindowPoint: location)
            pinchCentroid = nil
        }
    }

    /// Whether this pinch has to move the map itself.
    private var pansItself: Bool {
        SceneGesture.pinchPansItself(
            secondsSinceScroll: lastScrollAt.map { CACurrentMediaTime() - $0 }
        )
    }

    /// A two-finger double tap, which every canvas on this platform answers by
    /// framing what is under the pointer.
    override func smartMagnify(with event: NSEvent) {
        canvas?.smartZoom(atWindowPoint: event.locationInWindow)
    }

    /// How far a ⌘-scroll has to travel on a trackpad to double the zoom.
    private static let pointsPerDoubling: CGFloat = 260
}

/// A clip view that centres a building smaller than the window.
///
/// The default puts a document smaller than the clip view in the corner, which
/// for a page is right and for an office is a room stuck to the top left of an
/// otherwise empty dark rectangle. Centring is also what ``SceneViewport``'s
/// own clamp does, so the camera and the scroll view keep agreeing about where
/// a small office is.
private final class SceneClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        if document.frame.width < rect.width {
            rect.origin.x = (document.frame.width - rect.width) / 2
        }
        if document.frame.height < rect.height {
            rect.origin.y = (document.frame.height - rect.height) / 2
        }
        return rect
    }
}

/// The scrollable extent of the office, and the surface the pointer lands on.
///
/// It draws nothing. Its whole job is to be the size of the building so the
/// scroll view knows how far there is to go, and to be the view the window
/// hands clicks and mouse-moved events to — which it forwards as points on the
/// floor plan, a space that does not move when the camera does.
///
/// It is flipped so that its coordinates *are* the floor plan's, shifted to the
/// document's origin: y down, the way a plan is read.
///
/// ## Why it must never draw
///
/// A document view is scaled by the scroll view's magnification, so at 4× this
/// view is four times the size of a building that is already larger than any
/// window. Layer-backed — which everything under a SwiftUI representable is —
/// that would be a backing store of hundreds of megabytes for a view whose
/// content is nothing at all. Answering `wantsUpdateLayer` keeps AppKit from
/// ever allocating one.
private final class SceneDocumentView: NSView {
    weak var canvas: SceneCanvasView?
    private var tracking: NSTrackingArea?

    override var isFlipped: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {}
    override var isOpaque: Bool { false }

    /// A click into an inactive window lands on the office rather than only
    /// raising the window, the way every canvas on this platform behaves.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        // `inVisibleRect` keeps the tracked area to the part of the document
        // that is actually on screen — which matters here, because the document
        // is the whole building and at 4× it is enormous.
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: self
        )
        addTrackingArea(area)
        tracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        canvas?.hover(atWindowPoint: event.locationInWindow)
    }

    override func mouseExited(with event: NSEvent) {
        canvas?.hover(atWindowPoint: nil)
    }

    override func mouseDown(with event: NSEvent) {
        canvas?.click(atWindowPoint: event.locationInWindow, clickCount: event.clickCount)
    }
}
