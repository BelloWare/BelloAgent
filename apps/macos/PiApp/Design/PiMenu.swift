import AppKit
import SwiftUI

// Menus the app builds on the press that opens them.
//
// A SwiftUI `Menu` is an AppKit pop-up button that SwiftUI keeps in step with
// the menu's content: every update of the view holding it rebuilt every item
// (its title, its symbol image, its accessibility text, read from a strings
// table per item) and set the button's font again, which invalidates the
// button's size. Inside the sidebar's lazy list that invalidation asked the
// list to lay out again, the list's pass updated its items' phases, and the
// items' buttons were updated again: on macOS 26 one update scheduled the
// next for ever, and 0.1.89 froze for good while a chat compacted.
//
// Here a menu is a list of values, turned into an `NSMenu` only when it opens.
// Its control is a SwiftUI face with an AppKit press target over it that
// never changes its own size, so nothing in it can ask for another layout.

/// One command of a menu.
struct PiMenuItem {
    var title: String
    var systemImage: String? = nil
    var enabled = true
    /// A right-click menu marks it as SwiftUI does; a menu built here draws
    /// it as the system draws every other command.
    var destructive = false
    /// Drawn with a checkmark, as the current choice.
    var checked = false
    var identifier: String? = nil
    var help: String? = nil
    var perform: @MainActor () -> Void
}

/// One line of a menu the app builds when it opens.
enum PiMenuEntry {
    case item(PiMenuItem)
    case submenu(title: String, systemImage: String?, identifier: String?, help: String?, entries: [PiMenuEntry])
    case separator
    /// A line of text that is not a command, such as a section's caption.
    case note(String)

    static func button(_ title: String, systemImage: String? = nil, enabled: Bool = true, destructive: Bool = false,
                       checked: Bool = false, identifier: String? = nil, help: String? = nil,
                       action: @escaping @MainActor () -> Void) -> PiMenuEntry {
        .item(PiMenuItem(title: title, systemImage: systemImage, enabled: enabled, destructive: destructive, checked: checked,
                         identifier: identifier, help: help, perform: action))
    }
    static func menu(_ title: String, systemImage: String? = nil, identifier: String? = nil, help: String? = nil,
                     @PiMenuBuilder _ entries: () -> [PiMenuEntry]) -> PiMenuEntry {
        .submenu(title: title, systemImage: systemImage, identifier: identifier, help: help, entries: entries())
    }
    static var divider: PiMenuEntry { .separator }

    var isSeparator: Bool { if case .separator = self { return true }; return false }

    /// What a menu shows: no separator at either end or two in a row, the
    /// way a menu whose sections came out empty should read.
    static func tidy(_ entries: [PiMenuEntry]) -> [PiMenuEntry] {
        var result: [PiMenuEntry] = []
        for entry in entries {
            if entry.isSeparator, result.isEmpty || result.last?.isSeparator == true { continue }
            result.append(entry)
        }
        while result.last?.isSeparator == true { result.removeLast() }
        return result
    }
}

/// Builds `[PiMenuEntry]` with `if`, `for` and nested groups, as a
/// `@ViewBuilder` builds a menu's views.
@resultBuilder enum PiMenuBuilder {
    static func buildBlock(_ parts: [PiMenuEntry]...) -> [PiMenuEntry] { parts.flatMap { $0 } }
    static func buildExpression(_ entry: PiMenuEntry) -> [PiMenuEntry] { [entry] }
    static func buildExpression(_ entries: [PiMenuEntry]) -> [PiMenuEntry] { entries }
    static func buildOptional(_ entries: [PiMenuEntry]?) -> [PiMenuEntry] { entries ?? [] }
    static func buildEither(first entries: [PiMenuEntry]) -> [PiMenuEntry] { entries }
    static func buildEither(second entries: [PiMenuEntry]) -> [PiMenuEntry] { entries }
    static func buildArray(_ parts: [[PiMenuEntry]]) -> [PiMenuEntry] { parts.flatMap { $0 } }
}

/// Turns entries into an `NSMenu` and shows it under the control that asked.
@MainActor enum PiMenus {
    /// Tests look at the menu a press builds instead of running the menu's
    /// own event loop, which would wait for a person to choose.
    static var intercept: ((NSMenu, NSView) -> Void)?
    /// How many menus have been built. A menu is built when it opens and at
    /// no other time; tests count.
    private(set) static var built = 0

    static func menu(_ entries: [PiMenuEntry]) -> NSMenu {
        built &+= 1
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in PiMenuEntry.tidy(entries) { menu.addItem(item(for: entry)) }
        return menu
    }

    private static func item(for entry: PiMenuEntry) -> NSMenuItem {
        switch entry {
        case .separator:
            return .separator()
        case .note(let text):
            let item = NSMenuItem(title: text, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        case .item(let command):
            let target = PiMenuTarget(command.perform)
            let item = NSMenuItem(title: command.title, action: #selector(PiMenuTarget.run(_:)), keyEquivalent: "")
            // A menu item holds its target weakly; the represented object keeps it.
            item.target = target; item.representedObject = target
            item.isEnabled = command.enabled
            item.state = command.checked ? .on : .off
            decorate(item, systemImage: command.checked ? nil : command.systemImage, identifier: command.identifier, help: command.help)
            return item
        case .submenu(let title, let systemImage, let identifier, let help, let entries):
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.submenu = menu(entries)
            decorate(item, systemImage: systemImage, identifier: identifier, help: help)
            return item
        }
    }

    private static func decorate(_ item: NSMenuItem, systemImage: String?, identifier: String?, help: String?) {
        if let systemImage { item.image = NSImage(systemSymbolName: systemImage, accessibilityDescription: nil) }
        if let identifier { item.identifier = NSUserInterfaceItemIdentifier(identifier); item.setAccessibilityIdentifier(identifier) }
        item.toolTip = help
    }

    /// Builds the menu now, and shows it under `anchor`.
    static func popUp(_ entries: [PiMenuEntry], below anchor: NSView) {
        let menu = menu(entries)
        if let intercept { intercept(menu, anchor); return }
        guard anchor.window != nil, !menu.items.isEmpty else { return }
        let origin = NSPoint(x: 0, y: anchor.isFlipped ? anchor.bounds.maxY + 4 : anchor.bounds.minY - 4)
        _ = menu.popUp(positioning: nil, at: origin, in: anchor)
    }

    /// Runs the command with this identifier in a built menu, as choosing it
    /// would. For tests.
    @discardableResult static func perform(_ identifier: String, in menu: NSMenu) -> Bool {
        for item in menu.items {
            if item.identifier?.rawValue == identifier, item.isEnabled, let target = item.target as? PiMenuTarget {
                target.run(item); return true
            }
            if let submenu = item.submenu, perform(identifier, in: submenu) { return true }
        }
        return false
    }
}

@MainActor final class PiMenuTarget: NSObject {
    private let perform: @MainActor () -> Void
    init(_ perform: @escaping @MainActor () -> Void) { self.perform = perform }
    @objc func run(_ sender: Any?) { perform() }
}

/// The press target of a menu control: the AppKit button laid over its face.
/// Its size is the face's, given by SwiftUI; updating it never changes its
/// font, title or image, so it never asks the layout around it to run again.
struct PiMenuTrigger: NSViewRepresentable {
    let label: String
    var identifier: String?
    var help: String
    let onHover: (Bool) -> Void
    let entries: @MainActor () -> [PiMenuEntry]

    func makeNSView(context: Context) -> PiPopoverTriggerButton {
        let button = PiPopoverTriggerButton(frame: .zero)
        button.setAccessibilityRole(.menuButton)
        apply(to: button, enabled: context.environment.isEnabled)
        return button
    }
    func updateNSView(_ button: PiPopoverTriggerButton, context: Context) { apply(to: button, enabled: context.environment.isEnabled) }
    private func apply(to button: PiPopoverTriggerButton, enabled: Bool) {
        let entries = entries
        button.onHover = onHover
        button.onPress = { anchor in PiMenus.popUp(entries(), below: anchor) }
        if button.isEnabled != enabled { button.isEnabled = enabled }
        if button.toolTip != help { button.toolTip = help.isEmpty ? nil : help }
        if button.accessibilityLabel() != label { button.setAccessibilityLabel(label) }
        if button.accessibilityIdentifier() != (identifier ?? "") { button.setAccessibilityIdentifier(identifier) }
    }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: PiPopoverTriggerButton, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// A control that opens a menu built on the press: the face is SwiftUI, drawn
/// by the caller with the hover state; the menu is `entries()` at that moment.
struct PiMenuControl<Face: View>: View {
    let label: String
    var identifier: String? = nil
    var help: String = ""
    let entries: @MainActor () -> [PiMenuEntry]
    @ViewBuilder var face: (_ hovering: Bool) -> Face
    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled

    init(label: String, identifier: String? = nil, help: String = "", @PiMenuBuilder entries: @escaping @MainActor () -> [PiMenuEntry],
         @ViewBuilder face: @escaping (_ hovering: Bool) -> Face) {
        self.label = label; self.identifier = identifier; self.help = help; self.entries = entries; self.face = face
    }

    var body: some View {
        face(hovering && enabled)
            .opacity(enabled ? 1 : 0.35)
            .accessibilityHidden(true)
            .overlay {
                PiMenuTrigger(label: label, identifier: identifier, help: help.isEmpty ? label : help,
                              onHover: { inside in if hovering != inside { hovering = inside } }, entries: entries)
            }
    }
}

/// The same entries as SwiftUI buttons, for a right-click menu. A context
/// menu's content is read when it opens.
struct PiMenuContent: View {
    let entries: @MainActor () -> [PiMenuEntry]
    init(@PiMenuBuilder _ entries: @escaping @MainActor () -> [PiMenuEntry]) { self.entries = entries }
    var body: some View {
        let lines = PiMenuEntry.tidy(entries())
        ForEach(lines.indices, id: \.self) { index in PiMenuLine(entry: lines[index]) }
    }
}

private struct PiMenuLine: View {
    let entry: PiMenuEntry
    var body: some View {
        switch entry {
        case .separator: Divider()
        case .note(let text): Text(text)
        case .item(let item):
            Group {
                if let symbol = item.checked ? "checkmark" : item.systemImage {
                    Button(role: item.destructive ? .destructive : nil, action: item.perform) { Label(item.title, systemImage: symbol) }
                } else {
                    Button(item.title, role: item.destructive ? .destructive : nil, action: item.perform)
                }
            }
            .disabled(!item.enabled)
            .modifier(PiMenuLineIdentity(identifier: item.identifier, help: item.help))
        case .submenu(let title, let systemImage, let identifier, let help, let entries):
            Menu {
                ForEach(entries.indices, id: \.self) { index in PiMenuLine(entry: entries[index]) }
            } label: {
                if let systemImage { Label(title, systemImage: systemImage) } else { Text(title) }
            }
            .modifier(PiMenuLineIdentity(identifier: identifier, help: help))
        }
    }
}

private struct PiMenuLineIdentity: ViewModifier {
    let identifier: String?
    let help: String?
    @ViewBuilder func body(content: Content) -> some View {
        switch (identifier, help) {
        case (let identifier?, let help?): content.accessibilityIdentifier(identifier).help(help)
        case (let identifier?, nil): content.accessibilityIdentifier(identifier)
        case (nil, let help?): content.help(help)
        case (nil, nil): content
        }
    }
}
