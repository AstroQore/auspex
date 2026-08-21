import SwiftUI

/// The one way Auspex says "there is nothing here".
///
/// ## Why one view rather than a phrase per place
///
/// An app that is mostly *other people's* activity is empty a lot: a column
/// nobody has filed anything into, a trace before a card is picked, a step list
/// a brush has emptied. Every one of those had grown its own answer — a dash, a
/// boxed paragraph, a 22 pt headline — and the effect was that emptiness looked
/// like six different things, three of which looked like a control that had
/// failed to draw.
///
/// So it is one shape everywhere: a mark, a line, and at most a sentence, all
/// in the third text step. It is deliberately the quietest thing on screen.
/// Nothing is wrong when a column is empty, and a panel with a border around
/// the word "empty" says the opposite.
///
/// ## Why there is no box
///
/// A frame is a promise that something is inside it. Drawing one around
/// nothing is how a placeholder ends up looking like a broken control — which
/// is exactly what the dashes in the task columns looked like. The container
/// that *has* content keeps its chrome; the empty one draws the line and no
/// more.
struct EmptyStateView<Action: View>: View {
    /// An SF Symbol above the line. Omitted where the surrounding chrome
    /// already says what kind of thing is missing — a marked-up icon over a
    /// six-point-tall column header is noise.
    var symbol: String?
    let title: String
    /// One sentence at most. Anything longer is documentation, and belongs
    /// where a person went looking for it.
    var detail: String?
    /// A link under the line, for the empty states a person put themselves in
    /// — a filter that matched nothing, a brush over a quiet stretch.
    @ViewBuilder var action: () -> Action

    var body: some View {
        VStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .font(.system(size: 18, weight: .light))
                    .foregroundStyle(AuspexPalette.text3)
                    .accessibilityHidden(true)
            }
            Text(title)
                .font(AuspexType.emptyTitle)
                .foregroundStyle(AuspexPalette.text3)
            if let detail {
                Text(detail)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            action()
                .font(AuspexType.caption)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: Self.measure)
        .padding(.horizontal, 14)
        .padding(.vertical, 16)
    }

    /// How wide the sentence is allowed to get before it wraps. A centred line
    /// running the full width of a 1180 pt page is unreadable, and the shape of
    /// this thing is a small stack in the middle of a space, not a banner.
    static var measure: CGFloat { 340 }
}

extension EmptyStateView where Action == EmptyView {
    init(symbol: String? = nil, title: String, detail: String? = nil) {
        self.init(symbol: symbol, title: title, detail: detail) { EmptyView() }
    }
}

extension View {
    /// Centres an empty state in whatever space it was given.
    ///
    /// A modifier rather than a parameter on the view, because half the call
    /// sites want the line centred in a whole pane and half want it sitting
    /// where the missing rows would have been.
    func centredInPane() -> some View {
        frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
