import AgentSessionKit
import AuspexCore
import SwiftUI

/// Settings → Ignore: everything the board is not showing, and why.
///
/// The list is the whole feature. A rule written from a card's context menu and
/// a rule typed here are the same row, and this is the only place all of them
/// can be seen at once — which matters more than usual, because the symptom of
/// a forgotten rule is a session that is simply not there.
struct IgnoreSettingsView: View {
    let catalog: ProjectCatalogModel

    @State private var tag: IgnoreRule.Kind.Tag = .pathPrefix
    @State private var value = ""

    private var rules: [IgnoreRule] { catalog.settings.ignoreRules }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                addRow
                list
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AuspexPalette.canvas)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "eye.slash")
                    .font(.system(size: 10, weight: .semibold))
                Text("Ignore").auspexLabel()
            }
            .foregroundStyle(AuspexPalette.statePermission)

            Text(headline)
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.text)

            Text(IgnoreCopy.stillRecorded)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text2)
                .fixedSize(horizontal: false, vertical: true)

            if let error = catalog.saveErrorDescription {
                Label(
                    "Your change is in effect but could not be saved: \(error)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.statePermission)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var headline: String {
        let active = rules.count(where: \.isEnabled)
        guard !rules.isEmpty else { return "Nothing is being hidden." }
        let noun = rules.count == 1 ? "rule" : "rules"
        guard active != rules.count else { return "\(rules.count) \(noun)." }
        return "\(rules.count) \(noun), \(active) of them on."
    }

    // MARK: Adding

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionRule("Add a rule", detail: tag.explanation)
            HStack(spacing: 8) {
                Picker("", selection: $tag) {
                    ForEach(IgnoreRule.Kind.Tag.allCases) { tag in
                        Text(tag.label).tag(tag)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                if tag == .harness {
                    Picker("", selection: $value) {
                        Text("Choose a harness").tag("")
                        ForEach(AuspexAdapters.featured, id: \.self) { harness in
                            Text(harness.displayName).tag(harness.rawValue)
                        }
                    }
                    .labelsHidden()
                } else {
                    TextField(tag.placeholder, text: $value)
                        .textFieldStyle(.roundedBorder)
                        .font(tag == .pathPrefix ? AuspexType.monoSmall : AuspexType.body)
                        .onSubmit { add() }
                }

                Button("Add") { add() }
                    .controlSize(.small)
                    .disabled(IgnoreRule.Kind.make(tag: tag, value: value) == nil)
            }
        }
    }

    private func add() {
        guard let kind = IgnoreRule.Kind.make(tag: tag, value: value) else { return }
        catalog.add(rule: IgnoreRule(kind: kind))
        value = ""
    }

    // MARK: The rules

    @ViewBuilder
    private var list: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionRule("Rules", detail: "Switch one off to try the board without it.")
            if rules.isEmpty {
                Text(
                    "No rules yet. Right-click a card or a project in the sidebar to ignore "
                        + "the folder it is in, the project it belongs to, or every session "
                        + "whose prompt starts the same way."
                )
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelChrome()
            } else {
                VStack(spacing: 0) {
                    ForEach(rules) { rule in
                        row(rule)
                        if rule.id != rules.last?.id {
                            Divider().overlay(AuspexPalette.line)
                        }
                    }
                }
                .panelChrome()
            }
        }
    }

    private func row(_ rule: IgnoreRule) -> some View {
        HStack(spacing: 10) {
            Toggle(
                isOn: Binding(
                    get: { rule.isEnabled },
                    set: { _ in catalog.toggle(rule: rule) }
                )
            ) { EmptyView() }
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)

            Text(rule.kind.label)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                .frame(width: 118, alignment: .leading)

            Text(rule.kind.value)
                .font(
                    rule.kind.tag == .pathPrefix ? AuspexType.monoSmall : AuspexType.rowTitle
                )
                .foregroundStyle(rule.isEnabled ? AuspexPalette.text : AuspexPalette.text3)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)

            Spacer(minLength: 8)

            Button {
                catalog.delete(rule: rule)
            } label: {
                Image(systemName: "trash")
                    .font(.system(size: 11))
                    .foregroundStyle(AuspexPalette.text3)
            }
            .buttonStyle(.plain)
            .help("Delete this rule")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .opacity(rule.isEnabled ? 1 : 0.6)
    }
}
