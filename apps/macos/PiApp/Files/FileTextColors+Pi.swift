import AppKit

// Bello Agent's own look for the file viewer's engine (`FileTextView`), which
// itself depends on nothing of the app: its colours and its context menu, in
// the app's design components.

extension FileTextColors {
    static let pi = FileTextColors(text: .piInk, lineNumber: .piInkTertiary, strongLineNumber: .piInkSecondary, emphasis: .piAccentSoft)
}

extension FileTextView {
    /// The app's colours and its own menus, for a view the app shows.
    func usePiDesign() {
        colors = .pi
        contextMenu = { view in
            PiMenus.menu([
                .button("Copy", enabled: view.hasSelection, identifier: "file-text-copy") { [weak view] in view?.copy(nil) },
                .button("Select All", identifier: "file-text-select-all") { [weak view] in view?.selectAll(nil) },
            ])
        }
    }
}
