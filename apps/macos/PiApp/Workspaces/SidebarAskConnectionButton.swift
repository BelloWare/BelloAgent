import AppKit

/// Ask's connection chooser, with the project chips' capsule and menu face.
@MainActor final class SidebarAskConnectionButton: PiKit.ButtonBase {
    var entries: (() -> [PiMenuEntry])?
    private var connection = "Choose a connection"
    private var available = true
    private static let padding: CGFloat = 9
    private static var chevron: PiKit.Symbol { PiKit.Symbol("chevron.down", size: 9, weight: .semibold) }
    private var line: PiKit.Line {
        PiKit.Line(connection, font: SidebarProjectFilterBar.Chip.font, color: available ? .piInk : .piInkSecondary)
    }
    override init(frame: NSRect) {
        super.init(frame: frame)
        pressScales = false
        setAccessibilityRole(.menuButton); setAccessibilityLabel("Ask connection")
        setAccessibilityIdentifier("sidebarAskConnection")
        onPress = { [weak self] in guard let self else { return }; PiMenus.popUp(self.entries?() ?? [], below: self) }
    }
    required init?(coder: NSCoder) { fatalError("Not used from a nib") }
    func update(_ choice: SidebarAskConnection?) {
        let title = choice?.title ?? "Choose a connection", enabled = choice?.available ?? false
        guard title != connection || enabled != available else { return }
        connection = title; available = enabled
        setAccessibilityValue(title)
        toolTip = enabled ? "Ask chats in " + title : title + " · No mini model"
        invalidateIntrinsicContentSize(); redrawContent(); refreshFace()
    }
    override var intrinsicContentSize: NSSize {
        NSSize(width: line.size(scale: piScale).width + Self.padding * 2 + Self.chevron.layoutSize.width + 4, height: line.lineHeight + 10)
    }
    override func styleFace() {
        fill.backgroundColor = piCGColor(isPressedDown && isEffectivelyEnabled ? .piFillStrong : hovering && isEffectivelyEnabled ? .piFill : .piSurface)
        stroke.borderColor = piCGColor(.piHairlineStrong)
    }
    override func drawContent(in rect: CGRect) {
        let size = line.size(scale: piScale), chevron = Self.chevron.layoutSize
        line.draw(in: CGRect(x: Self.padding, y: PiKit.round((rect.height - size.height) / 2, piScale),
                             width: max(0, rect.width - Self.padding * 2 - chevron.width - 4), height: size.height), truncation: .end, scale: piScale)
        Self.chevron.draw(centredIn: CGRect(x: rect.width - Self.padding - chevron.width, y: 0, width: chevron.width, height: rect.height),
                          color: .piInkSecondary, scale: piScale)
    }

    static func menu(choices: [SidebarAskConnection], chosen: String?, choose: @escaping @MainActor (String) -> Void) -> [PiMenuEntry] {
        choices.map { choice in
            PiMenuEntry.button(choice.title + (choice.available ? "" : " · No mini model"), enabled: choice.available,
                               checked: choice.id == chosen, identifier: "sidebarAskConnection-" + choice.id,
                               help: choice.available ? "Ask only this connection's chats" : "Choose a mini model in Settings") { choose(choice.id) }
        }
    }
}
