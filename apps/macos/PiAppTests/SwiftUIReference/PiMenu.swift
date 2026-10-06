import AppKit
import SwiftUI
@testable import PiApp

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
            // The press target over it is the control; the face is drawing.
            .accessibilityElement(children: .ignore).accessibilityHidden(true)
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
