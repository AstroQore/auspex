import Observation
import SwiftUI

/// What just went on the clipboard, for about a second.
///
/// ## Why a copy needs to say anything at all
///
/// Copying is the one action in this window with no visible result. A click
/// that opens a folder, selects a session or resumes a terminal shows what it
/// did; a click that puts a session id on the pasteboard looks exactly like a
/// click that did nothing — which is how a person learns that the id is not
/// clickable and stops trying.
///
/// So it is worth one line at the bottom of the pane, for long enough to read
/// and not long enough to be in the way.
///
/// ## One of them, and no clock
///
/// A single shared object rather than a `@State` per affordance: there are a
/// dozen places in the trace header alone that copy something, and twelve
/// independent toasts could stack. It holds a string and one cancellable
/// sleep — nothing ticks, nothing animates while it is empty, and the overlay
/// that draws it is `EmptyView` the rest of the time. That matters here: the
/// window is asleep almost all day and the performance budget in `AGENTS.md`
/// § 4.1 is written against exactly that.
@MainActor
@Observable
final class CopyToast {
    static let shared = CopyToast()

    /// What to say, or `nil` when there is nothing to say.
    private(set) var message: String?

    /// How long a message stays up. Long enough to read four words, short
    /// enough that a second copy does not queue behind the first.
    static let duration: Duration = .milliseconds(1_200)

    @ObservationIgnored private var dismissal: Task<Void, Never>?

    private init() {}

    /// Says something, replacing whatever was being said.
    func show(_ message: String) {
        self.message = message
        dismissal?.cancel()
        dismissal = Task { [weak self] in
            try? await Task.sleep(for: Self.duration)
            guard !Task.isCancelled else { return }
            self?.message = nil
        }
    }

    /// Clears immediately. For a host going away.
    func clear() {
        dismissal?.cancel()
        dismissal = nil
        message = nil
    }
}

/// The toast itself: a capsule at the bottom of whatever it is over.
///
/// Bottom-centre because the top of every pane in this window is a header
/// somebody just clicked something in, and a message that lands under the
/// pointer covers the thing that produced it.
struct CopyToastView: View {
    var toast: CopyToast = .shared

    var body: some View {
        Group {
            if let message = toast.message {
                Text(message)
                    .font(AuspexType.pill)
                    .foregroundStyle(AuspexPalette.text)
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .frame(height: 26)
                    .background(
                        Capsule(style: .continuous)
                            .fill(AuspexPalette.bg3)
                            .overlay(
                                Capsule(style: .continuous)
                                    .strokeBorder(AuspexPalette.line2, lineWidth: 1)
                            )
                    )
                    .shadow(color: AuspexPalette.shade, radius: 12, y: 4)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .animation(.easeOut(duration: 0.14), value: toast.message)
        .padding(.bottom, 14)
        .allowsHitTesting(false)
    }
}

extension View {
    /// Hangs the copy toast at the bottom of this view.
    ///
    /// An overlay rather than a window: it belongs to the pane the copy
    /// happened in, and a floating panel would take key focus away from the
    /// list somebody is reading.
    func auspexCopyToast() -> some View {
        overlay(alignment: .bottom) { CopyToastView() }
    }
}

// MARK: - The affordances

/// One monospaced fact that copies itself when it is clicked.
///
/// ## Why plain click means copy, and never navigation
///
/// The facts in a session's header — its id, its pid, its model, its working
/// directory — exist to be *taken somewhere else*: into a terminal, into a
/// `kill`, into a message to a colleague. A person who clicks one wants it on
/// the clipboard, and there is nothing else a click on a hexadecimal id could
/// reasonably mean.
///
/// So the rule for the whole header is one line long: a mono fact copies, and
/// only things that look like controls navigate. That is what makes it safe
/// for every fact to be clickable at once — nothing here can take you
/// somewhere you did not ask to go.
struct CopyFact: View {
    /// What is drawn. Often shorter than what is copied — a session id is
    /// eight characters on screen and thirty-six on the clipboard.
    let text: String
    /// What lands on the pasteboard. Defaults to the drawn text.
    var value: String?
    /// What the thing is, in the words the toast and the tooltip use:
    /// "session ID", "pid", "the working directory".
    let what: String
    var font: Font = AuspexType.monoSmall
    var tint: Color = AuspexPalette.text3

    @State private var isHovering = false

    private var copied: String { value ?? text }

    var body: some View {
        Text(text)
            .font(font)
            .foregroundStyle(isHovering ? AuspexPalette.text2 : tint)
            .lineLimit(1)
            .underline(isHovering, color: AuspexPalette.line2)
            .contentShape(Rectangle())
            .onHover { isHovering = $0 }
            .onTapGesture { CopyToast.copy(copied, what: what) }
            .help("Click to copy \(what) — \(copied)")
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("Copy \(what)")
    }
}

extension CopyToast {
    /// Copies, and says so. The pair is always wanted together, and one call
    /// is what stops a copy somewhere from silently forgetting the toast.
    static func copy(_ value: String, what: String) {
        SessionActions.copy(value)
        shared.show("Copied \(what)")
    }
}

/// A ``FactChip`` that does something when it is clicked.
///
/// The chip family already says "this is a fact about where this session is";
/// this adds the one thing a reader kept trying: pressing it. `onOption` is
/// the ⌥-click — reveal in Finder, for the chips that name a place — and the
/// menu is where the rest of it lives, because a chip cannot advertise three
/// actions and stay a chip.
struct ActionChip<Menu: View>: View {
    let title: String
    var tint: Color?
    var isMono = false
    var help: String
    let action: () -> Void
    var onOption: (() -> Void)?
    @ViewBuilder var menu: Menu

    @State private var isHovering = false

    var body: some View {
        FactChip(tint: tint, isMono: isMono) {
            Text(title)
        }
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    isHovering ? AuspexPalette.line2 : .clear,
                    lineWidth: 1
                )
        )
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        // The modified click first, and at a higher priority, or the plain
        // one below swallows it.
        .highPriorityGesture(
            TapGesture().modifiers(.option).onEnded { onOption?() },
            including: onOption == nil ? .subviews : .all
        )
        .onTapGesture(perform: action)
        .contextMenu { menu }
        .help(help)
        .accessibilityAddTraits(.isButton)
    }
}

/// A chip whose click copies what it says.
struct CopyChip: View {
    let title: String
    var tint: Color?
    var isMono = false
    /// What the thing is, for the toast and the tooltip.
    let what: String
    /// What lands on the pasteboard, when it is not what is drawn.
    var value: String?

    var body: some View {
        ActionChip(
            title: title,
            tint: tint,
            isMono: isMono,
            help: "Click to copy \(what) — \(value ?? title)",
            action: { CopyToast.copy(value ?? title, what: what) }
        )
    }
}

extension ActionChip where Menu == EmptyView {
    init(
        title: String,
        tint: Color? = nil,
        isMono: Bool = false,
        help: String,
        action: @escaping () -> Void
    ) {
        self.init(
            title: title,
            tint: tint,
            isMono: isMono,
            help: help,
            action: action,
            onOption: nil,
            menu: { EmptyView() }
        )
    }
}
