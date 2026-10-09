import AgentSessionKit
import AppKit
import AuspexCore
import SwiftUI

/// Settings for the *shape* of the board: which directories are one project.
///
/// ## Two lists, and the difference between them matters
///
/// **Yours** are the projects a person made. They claim folders, they can be
/// renamed, coloured and pinned, and deleting one gives its sessions back to
/// the resolver.
///
/// **Automatic** are what the resolver found on the live board — one per git
/// root, exactly as the sidebar shows them. They are not rows in a file and
/// nothing about them can be edited; the only thing offered is to make one a
/// project of your own, which is a one-click claim on that root.
///
/// Showing both is what makes the page honest. A page that listed only the
/// user's projects would suggest that a machine with no projects has no
/// projects, when in fact it has thirty and Auspex worked all of them out.
struct ProjectsPageView: View {
    let catalog: ProjectCatalogModel
    /// The live tree, for the automatic list and the session counts.
    let tree: ProjectTree

    /// The task ledger, for the work column.
    ///
    /// Read out of the environment rather than taken as a parameter: this page
    /// is built in two places that belong to the window's own file, and a page
    /// asking for one more number should not mean editing the window. Optional
    /// because a preview or a renderer may draw the page with no app around it.
    @Environment(AppEnvironment.self) private var environment: AppEnvironment?

    @State private var isImporting = false
    @State private var isCreating = false

    var body: some View {
        // `BoardScroll`, not `ScrollView`: `ImageRenderer` cannot draw a
        // scroll view's content, and this page is one of the ones
        // `--render-board` photographs.
        BoardScroll {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error = catalog.saveErrorDescription {
                    Label(
                        L10n.Projects.saveError(error: error),
                        systemImage: "exclamationmark.triangle"
                    )
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.statePermission)
                    .fixedSize(horizontal: false, vertical: true)
                }
                yours
                automatic
            }
            .padding(20)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(BoardSurfaceBackground())
        .sheet(isPresented: $isCreating) {
            NewProjectSheet(catalog: catalog) { isCreating = false }
                // Presented from the hand-drawn board column, which disables
                // AppKit's effect. This form restores native Tab feedback,
                // then clears only the automatic initial responder.
                .auspexSystemControlFocus()
                .auspexNoInitialFocus()
        }
        .sheet(isPresented: $isImporting) {
            ImportProjectsSheet(catalog: catalog) { isImporting = false }
                .auspexSystemControlFocus()
                .auspexNoInitialFocus()
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                Text(L10n.Projects.eyebrow).auspexLabel()
            }
            .foregroundStyle(AuspexPalette.stateTool)

            Text(headline)
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.text)

            Text(L10n.Projects.intro)
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.text2)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button(L10n.Projects.new, systemImage: "plus") { isCreating = true }
                Button(L10n.Projects.import, systemImage: "square.and.arrow.down") {
                    isImporting = true
                }
                Spacer(minLength: 0)
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
    }

    private var headline: String {
        let mine = catalog.projects.count
        let auto = automaticProjects.count
        guard mine > 0 else {
            return auto == 0
                ? L10n.Projects.Headline.none
                : L10n.Projects.Headline.autoOnly(count: auto)
        }
        return L10n.Projects.Headline.mixed(mine: mine, auto: auto)
    }

    // MARK: Yours

    @ViewBuilder
    private var yours: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionRule(L10n.Projects.yours, detail: L10n.Projects.yoursDetail)
            if catalog.projects.isEmpty {
                Text(L10n.Projects.yoursEmpty)
                .font(AuspexType.body)
                .foregroundStyle(AuspexPalette.text3)
                .fixedSize(horizontal: false, vertical: true)
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .panelChrome()
            } else {
                VStack(spacing: 8) {
                    ForEach(catalog.projects) { project in
                        ProjectCard(
                            project: project,
                            catalog: catalog,
                            liveCount: liveCount(forKey: project.key),
                            sessionCount: sessionCount(forKey: project.key),
                            tasks: taskCounts(forKey: project.key)
                        )
                    }
                }
            }
        }
    }

    // MARK: Automatic

    /// Every project on the live board that no user project claims, plus the
    /// ones that hold tasks and nothing that is running.
    ///
    /// The second half is what keeps this page honest now that tasks are filed
    /// in projects: work outlives the session that filed it, and a project
    /// whose agents have all gone home would otherwise vanish from the page
    /// while its tasks stayed on the board.
    private var automaticProjects: [ProjectTree.Project] {
        let live = tree.projects.filter { catalog.claims.project(forKey: $0.key) == nil }
        let known = Set(tree.projects.map(\.key))
        let dormant = (environment?.tasks.projectTaskCounts ?? [:])
            .filter { !known.contains($0.key) && catalog.claims.project(forKey: $0.key) == nil }
            .keys
            .sorted()
            .map { key in
                ProjectTree.Project(
                    key: key,
                    name: key == TaskProject.scratchKey
                        ? L10n.Common.scratch
                        : BoardGrouping.projectName(forPath: key),
                    checkouts: [],
                    harnesses: [],
                    isRepository: false
                )
            }
        return live + dormant
    }

    @ViewBuilder
    private var automatic: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionRule(
                L10n.Projects.automatic,
                detail: L10n.Projects.automaticDetail
            )
            if automaticProjects.isEmpty {
                Text(L10n.Projects.automaticEmpty)
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text3)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelChrome()
            } else {
                VStack(spacing: 0) {
                    ForEach(automaticProjects) { project in
                        AutomaticProjectRow(
                            project: project,
                            catalog: catalog,
                            tasks: taskCounts(forKey: project.key)
                        )
                        if project.id != automaticProjects.last?.id {
                            Divider().overlay(AuspexPalette.line)
                        }
                    }
                }
                .panelChrome()
            }
        }
    }

    private func liveCount(forKey key: String) -> Int {
        tree.projects.first { $0.key == key }?.liveCount ?? 0
    }

    private func sessionCount(forKey key: String) -> Int {
        tree.projects.first { $0.key == key }?.sessionCount ?? 0
    }

    /// How much work is filed in a project — the one number this page was
    /// missing, now that a task belongs to a project rather than to a plan
    /// alongside one.
    private func taskCounts(forKey key: String) -> TaskProjectCounts {
        environment?.tasks.taskCounts(byProjectKey: key)
            ?? TaskProjectCounts(total: 0, open: 0)
    }
}

// MARK: - The work column

/// What a project is carrying, as one quiet pill.
///
/// Drawn only when there is something to say: a page of thirty repositories
/// with "0 tasks" beside each of them is thirty zeroes and no information.
private struct TaskCountPill: View {
    let counts: TaskProjectCounts

    var body: some View {
        if counts.total > 0 {
            HStack(spacing: 4) {
                Image(systemName: "checklist")
                    .font(.system(size: 9))
                Text(counts.localizedOpenDescription ?? L10n.Projects.allDone)
                    .font(AuspexType.caption)
            }
            .foregroundStyle(counts.open > 0 ? AuspexPalette.text2 : AuspexPalette.text3)
            .help(
                counts.open > 0
                    ? L10n.Projects.tasksHelp(open: counts.open, total: counts.total)
                    : L10n.Projects.allTasksDone
            )
        }
    }
}

// MARK: - One of yours

/// One user project: its name, its colour, what it claims, and where it came
/// from.
private struct ProjectCard: View {
    let project: AuspexProject
    let catalog: ProjectCatalogModel
    let liveCount: Int
    let sessionCount: Int
    let tasks: TaskProjectCounts

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                colourMenu
                // Editable in place: renaming a project is the most common
                // edit and a sheet for one text field is a sheet nobody wants.
                TextField(L10n.Projects.name, text: $name)
                    .textFieldStyle(.plain)
                    .font(AuspexType.cardTitle)
                    .foregroundStyle(AuspexPalette.text)
                    .auspexSystemControlFocus()
                    .onSubmit { catalog.rename(project, to: name) }
                    .frame(maxWidth: 260, alignment: .leading)

                if liveCount > 0 {
                    Text(L10n.Board.Section.live(count: liveCount))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AuspexPalette.stateWriting)
                } else if sessionCount > 0 {
                    Text(L10n.Projects.onBoard(count: sessionCount))
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                }
                TaskCountPill(counts: tasks)

                Spacer(minLength: 8)

                Button {
                    catalog.togglePin(project)
                } label: {
                    Image(systemName: project.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11))
                        .foregroundStyle(
                            project.isPinned ? AuspexPalette.stateTool : AuspexPalette.text3
                        )
                }
                .buttonStyle(.auspex)
                .help(project.isPinned ? L10n.Projects.unpinHelp : L10n.Projects.pinHelp)

                Button {
                    catalog.delete(project)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(AuspexPalette.text3)
                }
                .buttonStyle(.auspex)
                .help(L10n.Projects.deleteHelp)
            }

            roots

            if !project.members.isEmpty {
                Text(membersNote)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.text3)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .panelChrome()
        .onAppear { name = project.name }
        .onChange(of: project.name) { _, new in name = new }
    }

    private var colourMenu: some View {
        Menu {
            Button(L10n.Colour.none) { catalog.recolour(project, to: nil) }
            ForEach(ProjectColour.choices, id: \.hex) { choice in
                Button(choice.name) { catalog.recolour(project, to: choice.hex) }
            }
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(ProjectColour.color(project.colorHex) ?? AuspexPalette.line2)
                .frame(width: 10, height: 16)
        }
        .menuStyle(.button)
        .buttonStyle(.auspex)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(L10n.Projects.colourHelp)
    }

    private var roots: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(project.roots, id: \.self) { root in
                HStack(spacing: 6) {
                    Image(systemName: "folder")
                        .font(.system(size: 9))
                        .foregroundStyle(AuspexPalette.text3)
                    Text(root)
                        .font(AuspexType.monoSmall)
                        .foregroundStyle(AuspexPalette.text2)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                    Spacer(minLength: 8)
                    Button {
                        catalog.removeRoot(root, from: project)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.system(size: 10))
                            .foregroundStyle(AuspexPalette.text3)
                    }
                    .buttonStyle(.auspex)
                    .help(L10n.Projects.unclaimFolder)
                }
            }
            if project.roots.isEmpty {
                Text(L10n.Projects.claimsNothing)
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.stateStale)
            }
            Button(L10n.Projects.addFolder, systemImage: "plus") {
                guard let path = FolderPicker.choose() else { return }
                catalog.addRoot(path, to: project)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .auspexSystemControlFocus()
            .font(AuspexType.caption)
        }
    }

    private var membersNote: String {
        let harnesses = Set(project.members.map(\.harness))
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
            .joined(separator: ", ")
        return L10n.Projects.importedFrom(harnesses: harnesses)
    }
}

/// One project the resolver found, with the one thing that can be done to it.
private struct AutomaticProjectRow: View {
    let project: ProjectTree.Project
    let catalog: ProjectCatalogModel
    let tasks: TaskProjectCounts

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(AuspexType.rowTitle)
                    .foregroundStyle(AuspexPalette.text)
                Text(subtitle)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            TaskCountPill(counts: tasks)
            if project.liveCount > 0 {
                Text(L10n.Board.Section.live(count: project.liveCount))
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AuspexPalette.stateWriting)
            }
            // Only a directory can be claimed. A harness's pseudo project and
            // the scratch project are not paths, and offering to make a project
            // out of one would be offering to claim nothing.
            if TaskProject.subtitle(forKey: project.key) != nil {
                Button(L10n.Projects.makeAProject) {
                    catalog.addProject(name: project.name, roots: [project.key])
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// The line under the name: the directory, or why there is not one.
    private var subtitle: String {
        if project.key == TaskProject.scratchKey {
            return L10n.Projects.scratchSubtitle
        }
        return PseudoProject.isPseudo(project.key) ? L10n.Projects.noDirectory : project.key
    }
}

// MARK: - Parts

/// A rule with a label on it, the page's one section device.
struct SectionRule: View {
    let title: String
    var detail: String?

    init(_ title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(title).auspexLabel(AuspexType.labelSmall)
            if let detail {
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(AuspexPalette.text3)
            }
            Spacer(minLength: 4)
        }
        .foregroundStyle(AuspexPalette.text3)
        .overlay(alignment: .bottom) {
            Rectangle().fill(AuspexPalette.line).frame(height: 1).offset(y: 4)
        }
    }
}

/// The folder chooser, in one place.
///
/// `NSOpenPanel` rather than a text field alone, because a path typed by hand
/// is a path with a typo in it — and a claim on a directory that does not exist
/// claims nothing and says nothing about why.
enum FolderPicker {
    @MainActor
    static func choose(message: String = L10n.Projects.chooseFolder) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = L10n.Projects.claim
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
}
