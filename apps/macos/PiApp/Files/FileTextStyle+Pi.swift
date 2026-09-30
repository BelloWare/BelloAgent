import AppKit
import FileView

// Bello Agent's own look for the file viewer's engine (`FileTextView`), which
// itself depends on nothing of the app: its font and colours and its context
// menu, in the app's design components.

extension FileTextStyle {
    @MainActor static let pi = FileTextStyle(text: .piInk, lineNumber: .piInkTertiary, strongLineNumber: .piInkSecondary, emphasis: .piAccentSoft)
}

extension FileTextView {
    /// The app's look and its own menus, for a view the app shows.
    func usePiDesign() {
        style = .pi
        contextMenu = { view in
            PiMenus.menu([
                .button("Copy", enabled: view.hasSelection, identifier: "file-text-copy") { [weak view] in view?.copy(nil) },
                .button("Select All", identifier: "file-text-select-all") { [weak view] in view?.selectAll(nil) },
            ])
        }
    }
}
