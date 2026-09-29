import AppKit

/// SwiftUI keeps the window of every sheet it has presented after the sheet
/// is dismissed (macOS 14), hidden, with the sheet's views still in it: a new
/// window for each presentation, none of them shown again. Those views go on
/// observing the model, so every change to it redrew each sheet ever closed.
/// Ten closed Settings sheets made a model change cost five times what it did,
/// and the Settings and Projects sheets reported a layout cycle each time the
/// appearance changed. Once a sheet has ended and is off screen, its window
/// lets go of them. Only SwiftUI's own sheet windows are touched; an AppKit
/// sheet such as the quit question is left as it is.
@MainActor final class DismissedSheets: NSObject {
    static let shared = DismissedSheets()
    private struct Held { weak var window: NSWindow? }
    private var sheets: [Held] = []
    private var started = false

    func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(beginsSheet(_:)), name: NSWindow.willBeginSheetNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(endedSheet(_:)), name: NSWindow.didEndSheetNotification, object: nil)
    }

    /// The sheet is attached to its parent once this turn is over.
    @objc private func beginsSheet(_ note: Notification) {
        guard let parent = note.object as? NSWindow else { return }
        DispatchQueue.main.async { [weak self, weak parent] in
            MainActor.assumeIsolated {
                guard let self, let sheet = parent?.attachedSheet, Self.presentedBySwiftUI(sheet),
                      !self.sheets.contains(where: { $0.window === sheet }) else { return }
                self.sheets.append(Held(window: sheet))
            }
        }
    }

    /// The sheet leaves its parent once this turn is over.
    @objc private func endedSheet(_ note: Notification) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.releaseEnded() }
        }
    }

    private func releaseEnded() {
        for held in sheets {
            guard let sheet = held.window, !sheet.isVisible, sheet.sheetParent == nil else { continue }
            NotificationCenter.default.post(name: Self.willRelease, object: sheet)
            sheet.contentViewController = nil
            sheet.contentView = nil
        }
        sheets.removeAll { $0.window == nil || $0.window?.contentView == nil }
    }

    /// Posted with a closed sheet's window, off screen, just before the window
    /// lets go of its views. Letting go stops the views observing anything,
    /// but SwiftUI's sheet window keeps them and their state all the same,
    /// with the values they last drew. Content that holds much lets go of it
    /// here, while its views can still be laid out once, emptied. A sheet in
    /// a window of the app's own (`piSheetWindow`) is told the same way; its
    /// views then go with the window, and SwiftUI keeps nothing of them.
    static let willRelease = Notification.Name("DismissedSheetsWillRelease")

    /// SwiftUI presents `.sheet` in a window class of its own.
    static func presentedBySwiftUI(_ window: NSWindow) -> Bool {
        String(describing: type(of: window)).contains("SheetPresentationWindow")
    }
}
