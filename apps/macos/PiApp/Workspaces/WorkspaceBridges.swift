import AppKit

@MainActor enum AppKitSheets {
    static func present(on parent: NSWindow, size: NSSize, enabled: Bool = true, make: @escaping (_ dismiss: @escaping () -> Void) -> NSView) -> PiSheetWindow {
        weak var shown: PiSheetWindow?
        let close: @MainActor () -> Void = { shown?.end(animated: true, requested: true) }
        let content = make(close)
        content.setFrameSize(size)
        let sheet = PiSheetWindow(content: content,
                                  inherited: PiSheetWindowInherited(reduceMotion: PiKit.Motion.reduced, enabled: enabled), close: close)
        shown = sheet
        sheet.present(on: parent)
        return sheet
    }
}
