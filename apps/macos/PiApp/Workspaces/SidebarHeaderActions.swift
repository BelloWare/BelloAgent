import AppKit

/// The sidebar header and View menu use the same radio choices.
enum SidebarHeaderActions {
    @MainActor @PiMenuBuilder static func viewEntries(model: WorkspaceModel) -> [PiMenuEntry] {
        PiMenuEntry.button("Topics", systemImage: "folder", checked: !model.sidebarListsFlat, identifier: "sidebarView-topics",
                           help: "Group chats by project and topic") { model.setSidebarFlat(false) }
        PiMenuEntry.button("Flat", systemImage: "list.bullet", checked: model.sidebarListsFlat, identifier: "sidebarView-flat",
                           help: "Combine all projects, newest activity first, with project and topic tags") { model.setSidebarFlat(true) }
    }

    @MainActor @PiMenuBuilder static func entries(model: WorkspaceModel) -> [PiMenuEntry] {
        PiMenuEntry.note("Show Chats")
        viewEntries(model: model)
        PiMenuEntry.divider
        PiMenuEntry.button("Show Archived Chats", systemImage: "archivebox", checked: model.sidebarShowsArchived,
                           identifier: "sidebarShowArchived") { model.toggleArchivedChats() }
        PiMenuEntry.menu("Projects", systemImage: "folder", identifier: "sidebarProjects") {
            for project in model.sidebarProjects {
                PiMenuEntry.menu(project.name, systemImage: project.record.isScratch ? "tray" : "folder",
                                 identifier: "sidebarProjects-" + project.id) {
                    if project.record.isScratch {
                        PiMenuEntry.note("Chats outside any project · tools disabled")
                    } else {
                        ProjectSidebarActions.projectEntries(model: model,
                            state: ProjectHeaderState(projectID: project.id, name: project.name, trusted: project.record.trusted, available: project.available),
                            identifierPrefix: "sidebarProjects-" + project.id + "-")
                    }
                }
            }
        }
    }
}
