import SwiftUI

/// The main window: a sidebar of board sections and an empty detail pane.
///
/// Every section is a placeholder. The live board, project/task grouping, and
/// the harness inventory replace the detail pane in M1–M3.
struct RootView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var selection: BoardSection? = .live

    var body: some View {
        NavigationSplitView {
            List(environment.sections, selection: $selection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 168, ideal: 200, max: 280)
            .navigationTitle("Auspex")
        } detail: {
            PlaceholderDetailView(section: selection ?? .live)
        }
    }
}

/// Stand-in for every section's real content.
struct PlaceholderDetailView: View {
    @Environment(AppEnvironment.self) private var environment
    let section: BoardSection

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "eye")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)

            Text("Auspex — no sessions yet")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text(section.title)
                .font(.callout)
                .foregroundStyle(.tertiary)

            Text(environment.versionDescription)
                .font(.caption)
                .foregroundStyle(.quaternary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle(section.title)
    }
}
