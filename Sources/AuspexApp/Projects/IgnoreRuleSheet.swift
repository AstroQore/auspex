import AgentSessionKit
import AuspexCore
import SwiftUI

/// A rule somebody is about to write, opened from wherever they were.
///
/// A value rather than a set of `@State` flags because the menu items that
/// start one are on cards, on sidebar rows and in the settings pane, and the
/// sheet is presented once, at the root. The value carries the prefill — the
/// folder that was under the pointer, the project that was clicked — which is
/// the whole point of the "…" in the menu item: the rule is offered, not
/// applied behind somebody's back.
struct IgnoreDraft: Identifiable, Hashable {
    let id = UUID()
    var tag: IgnoreRule.Kind.Tag
    var value: String
}

/// The sheet: pick what to match on, check the text, add the rule.
struct IgnoreRuleSheet: View {
    let draft: IgnoreDraft
    let catalog: ProjectCatalogModel
    let onClose: () -> Void

    @State private var tag: IgnoreRule.Kind.Tag
    @State private var value: String

    init(draft: IgnoreDraft, catalog: ProjectCatalogModel, onClose: @escaping () -> Void) {
        self.draft = draft
        self.catalog = catalog
        self.onClose = onClose
        _tag = State(initialValue: draft.tag)
        _value = State(initialValue: draft.value)
    }

    private var kind: IgnoreRule.Kind? {
        IgnoreRule.Kind.make(tag: tag, value: value)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Ignore").auspexLabel().foregroundStyle(AuspexPalette.statePermission)
                Text("Hide these sessions from the board")
                    .font(AuspexType.display)
                    .foregroundStyle(AuspexPalette.text)
            }

            Picker("Match on", selection: $tag) {
                ForEach(IgnoreRule.Kind.Tag.allCases) { tag in
                    Text(tag.label).tag(tag)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            if tag == .harness {
                Picker("Harness", selection: $value) {
                    ForEach(AuspexAdapters.featured, id: \.self) { harness in
                        Text(harness.displayName).tag(harness.rawValue)
                    }
                }
                .labelsHidden()
            } else {
                TextField(tag.placeholder, text: $value)
                    .textFieldStyle(.roundedBorder)
                    .font(tag == .pathPrefix ? AuspexType.monoSmall : AuspexType.body)
            }

            Text(tag.explanation)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text2)
                .fixedSize(horizontal: false, vertical: true)

            Text(IgnoreCopy.stillRecorded)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text3)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Ignore") {
                    if let kind { catalog.add(rule: IgnoreRule(kind: kind)) }
                    onClose()
                }
                .disabled(kind == nil)
            }
        }
        .padding(20)
        .frame(width: 460)
        .background(AuspexPalette.canvas)
        .onChange(of: tag) { _, new in
            // A harness rule is a choice, not a string; seed the picker rather
            // than leaving the path that was prefilled in a field nobody can
            // see any more.
            if new == .harness, Harness(rawValue: value) == nil {
                value = AuspexAdapters.featured.first?.rawValue ?? Harness.claudeCode.rawValue
            }
        }
    }
}

/// The three offers every session makes, wherever it is drawn.
///
/// One view rather than a menu builder per surface: a card, an ended row and a
/// sidebar row are the same session, and a menu that offered different things
/// depending on which of them was under the pointer would be a menu nobody
/// learns.
struct SessionRowMenu: View {
    let row: BoardRow
    let model: LiveBoardModel
    let environment: AppEnvironment

    var body: some View {
        // The row's own directory is abbreviated for display; a rule needs the
        // path the session actually reported.
        if let directory = model.directoryPath(of: row.key) {
            Button("Ignore this folder…") {
                environment.composeIgnore(.pathPrefix, value: directory)
            }
        }
        if let project = row.project {
            Button("Ignore project…") {
                environment.composeIgnore(.project, value: project)
            }
        }
        Button("Ignore prompts starting with…") {
            environment.composeIgnore(.promptPrefix, value: row.title)
        }
        Divider()
        Button("Ignore every \(row.harness.displayName) session…") {
            environment.composeIgnore(.harness, value: row.harness.rawValue)
        }
        if let directory = model.directoryPath(of: row.key) {
            Divider()
            Button("Make this folder an Auspex project") {
                environment.catalog.addProject(
                    name: BoardGrouping.projectName(forPath: directory),
                    roots: [directory]
                )
            }
        }
    }
}

/// The sentence every ignore surface says, in one place so all of them say it
/// the same way.
enum IgnoreCopy {
    static let stillRecorded =
        "Ignored sessions are still recorded and still searchable — they are only "
        + "hidden from the board, the scene and the counts."
}
