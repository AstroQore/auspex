import AgentSessionKit
import AuspexCore
import SwiftUI

/// Making a project: a name, a colour, and the folders it claims.
///
/// The folders are the only part that has to be right, so the sheet refuses to
/// finish without one: a project claiming nothing places no session, and a row
/// on the page that does nothing is worse than a sheet that would not close.
struct NewProjectSheet: View {
    let catalog: ProjectCatalogModel
    let onClose: () -> Void

    @State private var name = ""
    @State private var colorHex: String?
    @State private var roots: [String] = []
    @State private var typedPath = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text("New project").auspexLabel().foregroundStyle(AuspexPalette.stateTool)
                Text("One project, any number of folders")
                    .font(AuspexType.display)
                    .foregroundStyle(AuspexPalette.text)
            }

            HStack(spacing: 8) {
                colourMenu
                TextField("Name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Folders").auspexLabel(AuspexType.labelSmall)
                    .foregroundStyle(AuspexPalette.text3)
                ForEach(roots, id: \.self) { root in
                    HStack(spacing: 6) {
                        Text(root)
                            .font(AuspexType.monoSmall)
                            .foregroundStyle(AuspexPalette.text2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Button {
                            roots.removeAll { $0 == root }
                        } label: {
                            Image(systemName: "minus.circle").font(.system(size: 10))
                        }
                        .buttonStyle(.auspex)
                        .foregroundStyle(AuspexPalette.text3)
                    }
                }
                HStack(spacing: 8) {
                    Button("Choose folder…", systemImage: "folder") {
                        guard let path = FolderPicker.choose() else { return }
                        add(path)
                    }
                    .controlSize(.small)
                    TextField("…or paste a path", text: $typedPath)
                        .textFieldStyle(.roundedBorder)
                        .font(AuspexType.monoSmall)
                        .onSubmit {
                            add(typedPath)
                            typedPath = ""
                        }
                }
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("Cancel", role: .cancel) { onClose() }
                    .keyboardShortcut(.cancelAction)
                Button("Create") {
                    catalog.addProject(name: chosenName, roots: roots, colorHex: colorHex)
                    onClose()
                }
                .disabled(roots.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .background(AuspexPalette.canvas)
    }

    /// The name, or the first folder's own name — which is what the resolver
    /// would have called it, and is right often enough to be the default.
    private var chosenName: String {
        let typed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed.isEmpty else { return typed }
        return roots.first.map(BoardGrouping.projectName(forPath:)) ?? "New project"
    }

    private func add(_ path: String) {
        let normalized = ProjectPath.normalize(path)
        guard normalized.hasPrefix("/"), !roots.contains(normalized) else { return }
        roots.append(normalized)
        if name.isEmpty { name = BoardGrouping.projectName(forPath: normalized) }
    }

    private var colourMenu: some View {
        Menu {
            Button("None") { colorHex = nil }
            ForEach(ProjectColour.choices, id: \.hex) { choice in
                Button(choice.name) { colorHex = choice.hex }
            }
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(ProjectColour.color(colorHex) ?? AuspexPalette.line2)
                .frame(width: 12, height: 18)
        }
        .menuStyle(.button)
        .buttonStyle(.auspex)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

/// Importing from a harness's own project registry.
///
/// The list is what Claude Code and Codex already believe your projects are —
/// hundreds of entries on a machine that has been used for a while — so it is
/// filtered, dated, and says which entries are already claimed. Ticking some
/// and choosing a destination is the whole interaction.
struct ImportProjectsSheet: View {
    let catalog: ProjectCatalogModel
    let onClose: () -> Void

    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var destination: UUID?

    /// How many rows are drawn before the filter has to do the work. A person
    /// scrolling four hundred paths is a person who should be typing instead.
    private static let limit = 200

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            TextField("Filter by path", text: $query)
                .textFieldStyle(.roundedBorder)
                .font(AuspexType.monoSmall)

            if catalog.isLoadingHarnessProjects {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                list
            }

            footer
        }
        .padding(20)
        .frame(width: 620, height: 560)
        .background(AuspexPalette.canvas)
        .task { await catalog.loadHarnessProjects() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Import").auspexLabel().foregroundStyle(AuspexPalette.stateTool)
            Text("Projects your harnesses already know about")
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.text)
            Text(
                "Read from each harness's own registry, and only the paths: Claude Code's "
                    + "projects folder and the project keys of ~/.claude.json, Codex's "
                    + "config.toml tables and its thread catalog. Nothing is written back."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.text2)
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var harnesses: [Harness] {
        Array(Set(catalog.harnessProjects.map(\.harness)))
            .sorted { $0.displayName < $1.displayName }
    }

    private func rows(for harness: Harness) -> [HarnessProjectRef] {
        let all = catalog.harnessProjects(for: harness)
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let matched = trimmed.isEmpty
            ? all
            : all.filter { $0.path.localizedCaseInsensitiveContains(trimmed) }
        return Array(matched.prefix(Self.limit))
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: [.sectionHeaders]) {
                ForEach(harnesses, id: \.self) { harness in
                    Section {
                        ForEach(rows(for: harness)) { ref in
                            row(ref)
                            Divider().overlay(AuspexPalette.line)
                        }
                    } header: {
                        HStack(spacing: 6) {
                            HarnessBadge(harness: harness, size: 16)
                            Text(harness.displayName)
                                .font(AuspexType.rowStrong)
                                .foregroundStyle(AuspexPalette.text2)
                            Text("\(catalog.harnessProjects(for: harness).count)")
                                .font(AuspexType.monoCount)
                                .foregroundStyle(AuspexPalette.text3)
                            Spacer(minLength: 0)
                        }
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(AuspexPalette.bg1)
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .panelChrome()
    }

    private func row(_ ref: HarnessProjectRef) -> some View {
        let claimed = catalog.claimingProject(for: ref.path)
        return HStack(spacing: 8) {
            Toggle(
                isOn: Binding(
                    get: { selected.contains(ref.path) },
                    set: { on in
                        if on { selected.insert(ref.path) } else { selected.remove(ref.path) }
                    }
                )
            ) { EmptyView() }
                .labelsHidden()
                .disabled(claimed != nil)

            VStack(alignment: .leading, spacing: 1) {
                Text(ref.displayName)
                    .font(AuspexType.rowTitle)
                    .foregroundStyle(AuspexPalette.text)
                Text(ref.path)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let claimed {
                Text("in \(claimed.name)")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
            } else if let seen = ref.lastSeen {
                Text(RelativeTimeText.since(seen))
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .opacity(claimed == nil ? 1 : 0.5)
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Picker("Into", selection: $destination) {
                Text("A new project").tag(UUID?.none)
                ForEach(catalog.projects) { project in
                    Text(project.name).tag(UUID?.some(project.id))
                }
            }
            .frame(width: 260)
            Spacer(minLength: 0)
            Text("\(selected.count) selected")
                .font(AuspexType.caption)
                .foregroundStyle(AuspexPalette.text3)
            Button("Cancel", role: .cancel) { onClose() }
                .keyboardShortcut(.cancelAction)
            Button("Add") {
                add()
                onClose()
            }
            .disabled(selected.isEmpty)
        }
    }

    private func add() {
        let refs = catalog.harnessProjects.filter { selected.contains($0.path) }
        guard !refs.isEmpty else { return }
        if let destination, let project = catalog.projects.first(where: { $0.id == destination }) {
            catalog.add(members: refs, to: project)
        } else {
            // One project holding everything that was ticked, named after the
            // first of them — a person importing six folders into one project
            // meant one project.
            catalog.addProject(
                name: refs[0].displayName,
                members: refs,
                createdBy: .imported
            )
        }
    }
}
