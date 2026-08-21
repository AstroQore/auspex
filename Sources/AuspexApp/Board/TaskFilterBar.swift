import AgentSessionKit
import AgentSessionLive
import AuspexCore
import SwiftUI

/// What the wall is narrowed to, and the one click that undoes it.
///
/// It only exists while something is on. A bar of six empty menus over a board
/// of eight cards is chrome; a bar that says *urgent · adapter · ready* over a
/// board of two is the answer to "why is this board so short", which is the
/// question a filter always eventually raises.
///
/// The menus themselves live in the header — see ``TaskFilterMenu`` — because
/// that is where a person goes to change how they are looking at something.
/// This is the receipt.
struct TaskFilterBar: View {
    @Bindable var model: LiveBoardModel

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal.decrease")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(AuspexPalette.stateThinking)
            if let importance = model.filters.importance {
                chip(importance.label) { model.filters.importance = nil }
            }
            if let label = model.filters.label {
                chip(label) { model.filters.label = nil }
            }
            if let harness = model.filters.harness {
                chip(harness.displayName) { model.filters.harness = nil }
            }
            if model.filters.readyOnly {
                chip("ready only") { model.filters.readyOnly = false }
            }
            if let claim = model.filters.claim {
                chip(claim.label) { model.filters.claim = nil }
            }
            if model.filters.orphanedOnly {
                chip("claim orphaned") { model.filters.orphanedOnly = false }
            }
            Spacer(minLength: 8)
            Button { model.filters = .none } label: {
                Text("Clear")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
                    .padding(.horizontal, 8)
                    .frame(height: 22)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(AuspexPalette.line, lineWidth: 1)
                    )
            }
            .buttonStyle(.auspex)
            .help("Show every task again")
        }
        .padding(.horizontal, 20)
        .frame(height: 32)
        .background(AuspexPalette.bg1)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.stateThinking.opacity(0.35)).frame(height: 1)
        }
    }

    /// One facet, with its own way off. Clicking the chip removes that facet
    /// rather than the whole filter — narrowing is done one question at a
    /// time, and so is widening.
    private func chip(_ text: String, onClear: @escaping () -> Void) -> some View {
        Button(action: onClear) {
            HStack(spacing: 4) {
                Text(text)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text2)
                Image(systemName: "xmark")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(AuspexPalette.text3)
            }
            .fixedSize()
            .padding(.horizontal, 7)
            .frame(height: 22)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(AuspexPalette.selection)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.auspex(cornerRadius: 6))
        .help("Stop filtering by \(text)")
    }
}

/// The menu in the header that narrows the wall.
///
/// One menu rather than five controls: on a busy machine every one of these is
/// off almost all of the time, and five permanently-visible pickers would take
/// the width the search field needs to be usable.
struct TaskFilterMenu: View {
    @Bindable var model: LiveBoardModel

    var body: some View {
        Menu {
            if !model.filterOptions.importances.isEmpty {
                Section("Importance") {
                    ForEach(model.filterOptions.importances, id: \.self) { importance in
                        toggle(importance.label, isOn: model.filters.importance == importance) {
                            model.filters.importance =
                                model.filters.importance == importance ? nil : importance
                        }
                    }
                }
            }
            if !model.filterOptions.labels.isEmpty {
                Section("Label") {
                    ForEach(model.filterOptions.labels, id: \.self) { label in
                        toggle(label, isOn: model.filters.label == label) {
                            model.filters.label = model.filters.label == label ? nil : label
                        }
                    }
                }
            }
            if model.filterOptions.harnesses.count > 1 {
                Section("Harness") {
                    ForEach(model.filterOptions.harnesses, id: \.self) { harness in
                        toggle(harness.displayName, isOn: model.filters.harness == harness) {
                            model.filters.harness =
                                model.filters.harness == harness ? nil : harness
                        }
                    }
                }
            }
            Section("Only") {
                if model.filterOptions.hasDependencies {
                    toggle("Ready to start", isOn: model.filters.readyOnly) {
                        model.filters.readyOnly.toggle()
                    }
                }
                ForEach(TaskFilters.Claim.allCases, id: \.self) { claim in
                    toggle(claim.label.capitalized, isOn: model.filters.claim == claim) {
                        model.filters.claim = model.filters.claim == claim ? nil : claim
                    }
                }
                if model.filterOptions.hasOrphans {
                    toggle("Orphaned claims", isOn: model.filters.orphanedOnly) {
                        model.filters.orphanedOnly.toggle()
                    }
                }
            }
            if !model.filters.isEmpty {
                Divider()
                Button("Clear filters") { model.filters = .none }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal.decrease")
                    .font(.system(size: 9, weight: .bold))
                if model.filters.count > 0 {
                    Text("\(model.filters.count)")
                        .font(AuspexType.caption)
                        .auspexTabularDigits()
                }
            }
            .foregroundStyle(
                model.filters.isEmpty ? AuspexPalette.text3 : AuspexPalette.stateThinking
            )
            .fixedSize()
        }
        .menuStyle(.button)
        .buttonStyle(.auspex(cornerRadius: 8))
        .menuIndicator(.hidden)
        .padding(.horizontal, 9)
        .frame(height: 28)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(model.filters.isEmpty ? AuspexPalette.bg1 : AuspexPalette.selection)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(AuspexPalette.line, lineWidth: 1)
                )
        )
        .help("Narrow the wall: importance, label, harness, what is ready, what is claimed")
    }

    private func toggle(
        _ title: String,
        isOn: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            if isOn {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }
}

/// What a right-click on a task card offers.
///
/// Ordered by what the gesture is *about*: what to do with the task, then
/// where it belongs, then what to do about the session behind it. Closing is
/// first because it is the one action this board exists to make one click.
struct TaskCardMenu: View {
    let unit: TaskUnit
    let model: LiveBoardModel
    let environment: AppEnvironment

    var body: some View {
        Button("Open task…") { model.openUnitID = unit.id }
        if unit.isInReview {
            Button("Close") { environment.tasks.close(unit: unit) }
        } else if unit.status == .done {
            Button("Reopen") { environment.tasks.reopen(unit: unit) }
        }
        if unit.origin.isImplicit {
            Button("Promote to task…") { environment.tasks.promote(unit: unit) }
        }
        if unit.isClaimOrphaned, let id = unit.origin.taskID {
            Button("Release claim") { environment.tasks.releaseClaim(taskID: id) }
        }
        Divider()
        if let session = model.session(for: unit.lead.key) {
            SessionActionsMenu(identity: session.identity, control: environment.control)
            Divider()
        }
        LinkToTaskMenu(key: unit.lead.key, tasks: environment.tasks)
        Divider()
        SessionRowMenu(row: unit.lead, model: model, environment: environment)
    }
}
