import AppKit
import GitView

// The diff drawn in the app's own look: its colours, and its context menu as
// the app's menus are drawn (`PiMenus`). The table itself knows neither.

extension GitDiffColors {
    /// The colours the diff has always been drawn in.
    @MainActor static let pi = GitDiffColors(text: .piInk, secondaryText: .piInkSecondary, tertiaryText: .piInkTertiary,
                                             added: .piSuccess, removed: .piDanger, hunk: .piInfo, separator: .piHairline,
                                             fileHeader: .piSurfaceSunken, emptySide: .piFill)
}

enum GitDiffPiMenu {
    /// Copy, Select All and, over a file's header, Copy Path.
    @MainActor static let builder: GitDiffMenuBuilder = { request in
        var entries: [PiMenuEntry] = [
            .button("Copy", enabled: request.hasSelection, identifier: "git-diff-copy", action: request.copy),
            .button("Select All", identifier: "git-diff-select-all", action: request.selectAll),
        ]
        if let path = request.filePath {
            entries.append(.divider)
            entries.append(.button("Copy Path", identifier: "git-diff-copy-path") {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(path, forType: .string)
            })
        }
        return PiMenus.menu(entries)
    }
}
