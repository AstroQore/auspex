import AgentSessionKit
import AuspexCore
import SwiftUI

struct MapRuleEditor: View {
    @Binding var rule: MapRule?
    @State private var draft: MapRuleDraft?
    @State private var validationError: String?

    init(rule: Binding<MapRule?>) {
        self._rule = rule
        self._draft = State(initialValue: rule.wrappedValue.map(MapRuleDraft.init))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.Perch.Rules.title).font(AuspexType.cardTitle)
                    Text(L10n.Perch.Rules.note)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                }
                Spacer()
                if draft == nil {
                    Button(L10n.Perch.Rules.add) { draft = .defaultRoot }
                        .buttonStyle(.auspex)
                } else {
                    Button(L10n.Common.clear) { draft = nil }
                        .buttonStyle(.auspex)
                }
            }

            if draft != nil {
                ScrollView {
                    RuleNodeEditor(node: Binding(
                        get: { draft ?? .defaultRoot },
                        set: { draft = $0 }
                    ), depth: 1)
                    .padding(10)
                }
                .frame(minHeight: 210, maxHeight: 300)
                .background(AuspexPalette.bg2)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack {
                if let validationError {
                    Text(validationError)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.statePermission)
                }
                Spacer()
                Button(L10n.Perch.Rules.apply) { apply() }
                    .buttonStyle(.auspex(cornerRadius: 7))
            }
        }
    }

    private func apply() {
        do {
            let value = try draft?.rule()
            try value?.validate()
            validationError = nil
            rule = value
        } catch {
            validationError = error.localizedDescription
        }
    }
}

private struct RuleNodeEditor: View {
    @Binding var node: MapRuleDraft
    let depth: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Picker(L10n.Perch.Rules.kind, selection: kindBinding) {
                    ForEach(MapRuleDraft.Kind.allCases, id: \.self) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .labelsHidden()
                .frame(width: 116)
                .auspexSystemControlFocus()
                if node.kind != .predicate, depth < MapRule.maximumDepth {
                    Button {
                        node.children.append(.defaultPredicate)
                    } label: {
                        Label(L10n.Perch.Rules.condition, systemImage: "plus")
                    }
                    .buttonStyle(.auspex)
                }
                Spacer()
            }

            if node.kind == .predicate {
                PredicateEditor(predicate: $node.predicate)
            } else {
                ForEach(node.children.indices, id: \.self) { index in
                    HStack(alignment: .top, spacing: 8) {
                        Rectangle()
                            .fill(AuspexPalette.line2)
                            .frame(width: 1)
                            .padding(.vertical, 4)
                        RuleNodeEditor(node: $node.children[index], depth: depth + 1)
                        Button {
                            node.children.remove(at: index)
                        } label: {
                            Image(systemName: "minus.circle")
                                .foregroundStyle(AuspexPalette.text3)
                        }
                        .buttonStyle(.auspex)
                        .accessibilityLabel(L10n.Perch.Rules.remove)
                    }
                    .padding(.leading, 10)
                }
                if node.children.isEmpty {
                    Text(node.kind == .all ? L10n.Perch.Rules.emptyAll : L10n.Perch.Rules.emptyGroup)
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                        .padding(.leading, 10)
                }
            }
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(depth.isMultiple(of: 2) ? AuspexPalette.bg1 : AuspexPalette.bg0)
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(AuspexPalette.line, lineWidth: 1)
                )
        )
    }

    private var kindBinding: Binding<MapRuleDraft.Kind> {
        Binding(
            get: { node.kind },
            set: { next in node.changeKind(to: next) }
        )
    }
}

private struct PredicateEditor: View {
    @Binding var predicate: MapRuleDraft.PredicateDraft

    var body: some View {
        HStack(spacing: 8) {
            Picker(L10n.Perch.Rules.field, selection: $predicate.field) {
                ForEach(MapRuleDraft.PredicateDraft.Field.allCases, id: \.self) {
                    Text($0.title).tag($0)
                }
            }
            .frame(width: 112)
            .auspexSystemControlFocus()
            valueControl
        }
    }

    @ViewBuilder
    private var valueControl: some View {
        switch predicate.field {
        case .project, .label:
            TextField(predicate.field == .project ? L10n.Perch.Rules.projectKey : L10n.Task.Filter.label, text: $predicate.text)
                .textFieldStyle(.roundedBorder)
                .auspexSystemControlFocus()
        case .harness:
            Picker(L10n.Common.harness, selection: $predicate.harness) {
                ForEach(Harness.allCases, id: \.self) { harness in
                    Text(harness.rawValue).tag(harness)
                }
            }
            .auspexSystemControlFocus()
        case .status:
            Picker(L10n.Common.status, selection: $predicate.status) {
                ForEach(AuspexTaskStatus.allCases, id: \.self) { status in
                    Text(status.rawValue).tag(status)
                }
            }
            .auspexSystemControlFocus()
        case .attention:
            Picker(L10n.Perch.Rules.attention, selection: $predicate.attention) {
                ForEach(MapAttentionKind.allCases, id: \.self) { attention in
                    Text(attention.title).tag(attention)
                }
            }
            .auspexSystemControlFocus()
        }
    }
}

private struct MapRuleDraft: Equatable {
    enum Kind: CaseIterable {
        case all
        case any
        case not
        case predicate

        var title: String {
            switch self {
            case .all: L10n.Perch.Rules.all
            case .any: L10n.Perch.Rules.any
            case .not: L10n.Perch.Rules.not
            case .predicate: L10n.Perch.Rules.condition
            }
        }
    }

    struct PredicateDraft: Equatable {
        enum Field: CaseIterable {
            case project
            case harness
            case label
            case status
            case attention

            var title: String {
                switch self {
                case .project: L10n.Common.project
                case .harness: L10n.Common.harness
                case .label: L10n.Task.Filter.label
                case .status: L10n.Common.status
                case .attention: L10n.Perch.Rules.attention
                }
            }
        }

        var field: Field = .project
        var text = ""
        var harness: Harness = .codex
        var status: AuspexTaskStatus = .doing
        var attention: MapAttentionKind = .working

        init(_ predicate: MapPredicate = .project("")) {
            switch predicate {
            case .project(let value): field = .project; text = value
            case .harness(let value): field = .harness; harness = value
            case .label(let value): field = .label; text = value
            case .status(let value): field = .status; status = value
            case .attention(let value): field = .attention; attention = value
            }
        }

        func predicate() -> MapPredicate {
            switch field {
            case .project: .project(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .harness: .harness(harness)
            case .label: .label(text.trimmingCharacters(in: .whitespacesAndNewlines))
            case .status: .status(status)
            case .attention: .attention(attention)
            }
        }
    }

    var kind: Kind
    var predicate: PredicateDraft
    var children: [MapRuleDraft]

    static let defaultPredicate = MapRuleDraft(
        kind: .predicate,
        predicate: PredicateDraft(),
        children: []
    )
    static let defaultRoot = MapRuleDraft(
        kind: .all,
        predicate: PredicateDraft(),
        children: [.defaultPredicate]
    )

    init(_ rule: MapRule) {
        switch rule {
        case .all(let children):
            kind = .all
            predicate = PredicateDraft()
            self.children = children.map(Self.init)
        case .any(let children):
            kind = .any
            predicate = PredicateDraft()
            self.children = children.map(Self.init)
        case .not(let child):
            kind = .not
            predicate = PredicateDraft()
            children = [Self(child)]
        case .predicate(let predicate):
            kind = .predicate
            self.predicate = PredicateDraft(predicate)
            children = []
        }
    }

    private init(kind: Kind, predicate: PredicateDraft, children: [MapRuleDraft]) {
        self.kind = kind
        self.predicate = predicate
        self.children = children
    }

    mutating func changeKind(to next: Kind) {
        guard kind != next else { return }
        kind = next
        switch next {
        case .predicate:
            children = []
        case .not:
            children = [children.first ?? .defaultPredicate]
        case .all, .any:
            if children.isEmpty { children = [.defaultPredicate] }
        }
    }

    func rule() throws -> MapRule {
        switch kind {
        case .all: .all(try children.map { try $0.rule() })
        case .any: .any(try children.map { try $0.rule() })
        case .not:
            .not(try (children.first ?? .defaultPredicate).rule())
        case .predicate:
            .predicate(predicate.predicate())
        }
    }
}

private extension MapAttentionKind {
    var title: String {
        switch self {
        case .needsYou: L10n.Now.needsYou
        case .review: L10n.Perch.Attention.review
        case .working: L10n.Now.working
        case .idle: L10n.Now.idle
        case .ended: L10n.Board.Ended.title
        }
    }
}
