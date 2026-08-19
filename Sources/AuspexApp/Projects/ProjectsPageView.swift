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
                        "Your change is in effect but could not be saved: \(error)",
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
        }
        .sheet(isPresented: $isImporting) {
            ImportProjectsSheet(catalog: catalog) { isImporting = false }
        }
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "folder")
                    .font(.system(size: 10, weight: .semibold))
                Text("Projects").auspexLabel()
            }
            .foregroundStyle(AuspexPalette.stateTool)

            Text(headline)
                .font(AuspexType.display)
                .foregroundStyle(AuspexPalette.text)

            Text(
                "Auspex groups sessions by git root on its own, so three worktrees of one "
                    + "repository are already one project. A project of your own claims "
                    + "folders instead: every session working under a claimed folder is "
                    + "placed in it, whatever git says, and the deepest claim wins when two "
                    + "overlap."
            )
            .font(AuspexType.body)
            .foregroundStyle(AuspexPalette.text2)
            .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("New project…", systemImage: "plus") { isCreating = true }
                Button("Import from harness…", systemImage: "square.and.arrow.down") {
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
                ? "No projects yet."
                : "\(auto) found on the board, none of them yours yet."
        }
        return "\(mine) yours, \(auto) more found on the board."
    }

    // MARK: Yours

    @ViewBuilder
    private var yours: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionRule("Yours", detail: "Claim folders; the board follows.")
            if catalog.projects.isEmpty {
                Text(
                    "Nothing yet. Make one from a folder, or import the projects Claude Code "
                        + "and Codex already know about."
                )
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
                            sessionCount: sessionCount(forKey: project.key)
                        )
                    }
                }
            }
        }
    }

    // MARK: Automatic

    /// Every project on the live board that no user project claims.
    private var automaticProjects: [ProjectTree.Project] {
        tree.projects.filter { catalog.claims.project(forKey: $0.key) == nil }
    }

    @ViewBuilder
    private var automatic: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionRule(
                "Automatic",
                detail: "Worked out from where sessions are running. Nothing is stored."
            )
            if automaticProjects.isEmpty {
                Text("Every project on the board is one of yours.")
                    .font(AuspexType.body)
                    .foregroundStyle(AuspexPalette.text3)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .panelChrome()
            } else {
                VStack(spacing: 0) {
                    ForEach(automaticProjects) { project in
                        AutomaticProjectRow(project: project, catalog: catalog)
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
}

// MARK: - One of yours

/// One user project: its name, its colour, what it claims, and where it came
/// from.
private struct ProjectCard: View {
    let project: AuspexProject
    let catalog: ProjectCatalogModel
    let liveCount: Int
    let sessionCount: Int

    @State private var name: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                colourMenu
                // Editable in place: renaming a project is the most common
                // edit and a sheet for one text field is a sheet nobody wants.
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(AuspexType.cardTitle)
                    .foregroundStyle(AuspexPalette.text)
                    .onSubmit { catalog.rename(project, to: name) }
                    .frame(maxWidth: 260, alignment: .leading)

                if liveCount > 0 {
                    Text("\(liveCount) live")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(AuspexPalette.stateWriting)
                } else if sessionCount > 0 {
                    Text("\(sessionCount) on the board")
                        .font(AuspexType.caption)
                        .foregroundStyle(AuspexPalette.text3)
                }

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
                .buttonStyle(.plain)
                .help(project.isPinned ? "Stop pinning it to the top" : "Pin it to the top")

                Button {
                    catalog.delete(project)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11))
                        .foregroundStyle(AuspexPalette.text3)
                }
                .buttonStyle(.plain)
                .help("Delete the project. Its sessions go back to where git puts them.")
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
            Button("None") { catalog.recolour(project, to: nil) }
            ForEach(ProjectColour.choices, id: \.hex) { choice in
                Button(choice.name) { catalog.recolour(project, to: choice.hex) }
            }
        } label: {
            RoundedRectangle(cornerRadius: 3, style: .continuous)
                .fill(ProjectColour.color(project.colorHex) ?? AuspexPalette.line2)
                .frame(width: 10, height: 16)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("The project's colour on the board")
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
                    .buttonStyle(.plain)
                    .help("Stop claiming this folder")
                }
            }
            if project.roots.isEmpty {
                Text("Claims nothing yet, so no session is placed in it.")
                    .font(AuspexType.caption)
                    .foregroundStyle(AuspexPalette.stateStale)
            }
            Button("Add folder…", systemImage: "plus") {
                guard let path = FolderPicker.choose() else { return }
                catalog.addRoot(path, to: project)
            }
            .controlSize(.small)
            .buttonStyle(.borderless)
            .font(AuspexType.caption)
        }
    }

    private var membersNote: String {
        let harnesses = Set(project.members.map(\.harness))
            .sorted { $0.displayName < $1.displayName }
            .map(\.displayName)
            .joined(separator: ", ")
        return "Imported from \(harnesses)."
    }
}

/// One project the resolver found, with the one thing that can be done to it.
private struct AutomaticProjectRow: View {
    let project: ProjectTree.Project
    let catalog: ProjectCatalogModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(AuspexType.rowTitle)
                    .foregroundStyle(AuspexPalette.text)
                Text(PseudoProject.isPseudo(project.key) ? "No working directory" : project.key)
                    .font(AuspexType.monoSmall)
                    .foregroundStyle(AuspexPalette.text3)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if project.liveCount > 0 {
                Text("\(project.liveCount) live")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(AuspexPalette.stateWriting)
            }
            if !PseudoProject.isPseudo(project.key) {
                Button("Make a project") {
                    catalog.addProject(name: project.name, roots: [project.key])
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
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
    static func choose(message: String = "Choose a folder for this project") -> String? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = message
        panel.prompt = "Claim"
        guard panel.runModal() == .OK else { return nil }
        return panel.url?.path
    }
}
