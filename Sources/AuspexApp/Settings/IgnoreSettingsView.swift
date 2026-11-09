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
        VStack(alignment: .leading, spacing: 18) {
            header
            addRow
            list
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Header

    /// How many rules there are right now, which is the one thing the pane's
    /// title row cannot say. The name and the line above it belong to the
    /// chrome — see ``AuspexSettingsView``.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(headline)
                .font(AuspexType.cardTitle)
                .foregroundStyle(AuspexPalette.text)

            Text(IgnoreCopy.stillRecorded)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text2)
                .fixedSize(horizontal: false, vertical: true)

            if let error = catalog.saveErrorDescription {
                Label(
                    L10n.Projects.saveError(error: error),
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
        guard !rules.isEmpty else { return L10n.Settings.Ignore.nothingHidden }
        guard active != rules.count else { return L10n.Settings.Ignore.rules(count: rules.count) }
        return L10n.Settings.Ignore.rulesOn(count: rules.count, active: active)
    }

    // MARK: Adding

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionRule(L10n.Settings.Ignore.addRule, detail: tag.localizedExplanation)
            HStack(spacing: 8) {
                Picker("", selection: $tag) {
                    ForEach(IgnoreRule.Kind.Tag.allCases) { tag in
                        Text(tag.localizedLabel).tag(tag)
                    }
                }
                .labelsHidden()
                .frame(width: 150)

                if tag == .harness {
                    Picker("", selection: $value) {
                        Text(L10n.Settings.Ignore.chooseHarness).tag("")
                        ForEach(AuspexAdapters.featured, id: \.self) { harness in
                            Text(harness.displayName).tag(harness.rawValue)
                        }
                    }
                    .labelsHidden()
                } else {
                    TextField(tag.localizedPlaceholder, text: $value)
                        .textFieldStyle(.roundedBorder)
                        .font(tag.takesPath ? AuspexType.monoSmall : AuspexType.body)
                        .onSubmit { add() }
                }

                Button(L10n.Common.add) { add() }
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
            SectionRule(L10n.Settings.Ignore.rulesTitle, detail: L10n.Settings.Ignore.rulesDetail)
            if rules.isEmpty {
                // No box: a border drawn around the sentence "there are no
                // rules" is a control that looks like it failed to load. See
                // ``EmptyStateView``.
                EmptyStateView(
                    title: L10n.Settings.Ignore.noRules,
                    detail: L10n.Settings.Ignore.noRulesDetail
                )
                .frame(maxWidth: .infinity)
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

            Text(rule.kind.localizedLabel)
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
                .frame(width: 118, alignment: .leading)

            Text(rule.kind.value)
                .font(
                    rule.kind.tag.takesPath ? AuspexType.monoSmall : AuspexType.rowTitle
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
            .buttonStyle(.auspex)
            .help(L10n.Settings.Ignore.deleteRule)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .opacity(rule.isEnabled ? 1 : 0.6)
    }
}
