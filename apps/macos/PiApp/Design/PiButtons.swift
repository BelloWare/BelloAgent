import SwiftUI
import AppKit

// MARK: - Buttons

/// Pointing-hand cursor for custom controls. AppKit only changes the cursor for
/// stock controls, so every clickable Pi component opts in; disabled controls
/// keep the arrow.
struct PiPointerModifier: ViewModifier {
    /// A control whose pointer is owned by an AppKit surface on top of it opts
    /// out instead of pushing a second cursor the surface would have to fight.
    var active = true
    @Environment(\.isEnabled) private var enabled
    @State private var pushed = false
    func body(content: Content) -> some View {
        content
            .onHover { hovering in
                if hovering && active && enabled && !pushed { NSCursor.pointingHand.push(); pushed = true }
                else if !hovering && pushed { NSCursor.pop(); pushed = false }
            }
            .onDisappear { if pushed { NSCursor.pop(); pushed = false } }
    }
}
extension View {
    /// Shows the pointing-hand cursor while hovering an enabled control.
    func piPointer() -> some View { modifier(PiPointerModifier()) }
}

/// Idle, hover and pressed fills for pill buttons, so a hovered button reads
/// as clickable before it is pressed.
private struct PiPillSurface: ViewModifier {
    let pressed: Bool
    let idle: Color, hover: Color, active: Color
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background(pressed ? active : hovering ? hover : idle, in: Capsule())
            .onHover { hovering = $0 }
            .piAnimation(PiMotion.quick, value: hovering)
    }
}

/// Flat brand-orange pill for the single primary action on a surface.
struct PiPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.piReduceMotion) private var reduceMotion
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(Color.piOnAccent)
            .padding(.horizontal, compact ? 12 : 16).padding(.vertical, compact ? 6 : 8)
            .modifier(PiPrimarySurface(pressed: configuration.isPressed))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .piAnimation(PiMotion.quick, value: configuration.isPressed)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .piPointer()
    }
}
/// Shade the flat fill on interaction without fading its foreground label.
private struct PiPrimarySurface: ViewModifier {
    let pressed: Bool
    @State private var hovering = false
    func body(content: Content) -> some View {
        content
            .background {
                Capsule().fill(Color.piBrandOrange)
                    .overlay(Capsule().fill(Color.black.opacity(pressed ? 0.10 : hovering ? 0.05 : 0)))
            }
            .shadow(color: Color.piBrandOrange.opacity(0.22), radius: 5, y: 2)
            .onHover { hovering = $0 }
            .piAnimation(PiMotion.quick, value: hovering)
    }
}
/// Soft, bordered pill for secondary actions.
struct PiSecondaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.piReduceMotion) private var reduceMotion
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .foregroundStyle(Color.piInk)
            .padding(.horizontal, compact ? 11 : 14).padding(.vertical, compact ? 5 : 7)
            .modifier(PiPillSurface(pressed: configuration.isPressed, idle: Color.piFill, hover: Color.piFillStrong, active: Color.piFillStrong))
            .overlay(Capsule().stroke(Color.piHairline, lineWidth: 1))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .piAnimation(PiMotion.quick, value: configuration.isPressed)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .piPointer()
    }
}
/// Text-only action that lights up on hover.
struct PiGhostButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.piReduceMotion) private var reduceMotion
    var tone: PiTone = .neutral
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .foregroundStyle(tone == .neutral ? Color.piInkSecondary : tone.color)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .modifier(PiPillSurface(pressed: configuration.isPressed, idle: Color.clear, hover: Color.piFill, active: Color.piFillStrong))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .piAnimation(PiMotion.quick, value: configuration.isPressed)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .piPointer()
    }
}
/// Destructive pill in a soft danger tint.
struct PiDangerButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    @Environment(\.piReduceMotion) private var reduceMotion
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(Color.piDanger)
            .padding(.horizontal, 12).padding(.vertical, 6)
            .modifier(PiPillSurface(pressed: configuration.isPressed, idle: Color.piDanger.opacity(0.12), hover: Color.piDanger.opacity(0.17), active: Color.piDanger.opacity(0.22)))
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
            .piAnimation(PiMotion.quick, value: configuration.isPressed)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Capsule())
            .piPointer()
    }
}
extension ButtonStyle where Self == PiPrimaryButtonStyle { static var piPrimary: PiPrimaryButtonStyle { PiPrimaryButtonStyle() }; static var piPrimaryCompact: PiPrimaryButtonStyle { PiPrimaryButtonStyle(compact: true) } }
extension ButtonStyle where Self == PiSecondaryButtonStyle { static var piSecondary: PiSecondaryButtonStyle { PiSecondaryButtonStyle() }; static var piSecondaryCompact: PiSecondaryButtonStyle { PiSecondaryButtonStyle(compact: true) } }
extension ButtonStyle where Self == PiGhostButtonStyle {
    static var piGhost: PiGhostButtonStyle { PiGhostButtonStyle() }
    /// The quiet form of a destructive action: the word is red, the control is
    /// not. A filled danger pill next to a primary button competes with it, and
    /// an action that only opens a confirmation has not destroyed anything yet.
    static var piGhostDanger: PiGhostButtonStyle { PiGhostButtonStyle(tone: .danger) }
}
extension ButtonStyle where Self == PiDangerButtonStyle { static var piDanger: PiDangerButtonStyle { PiDangerButtonStyle() } }

/// Symbol-only button with a soft hover circle.
struct PiIconButton: View {
    let symbol: String
    let label: String
    var tone: PiTone = .neutral
    var size: CGFloat = 28
    var filled = false
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size * 0.46, weight: .medium))
                .foregroundStyle(tone == .neutral ? Color.piInkSecondary : tone.color)
                .frame(width: size, height: size)
                .background(filled || hovering ? Color.piFillStrong : Color.clear, in: Circle())
                .contentShape(Circle())
                .piAnimation(PiMotion.quick, value: hovering)
        }
        .buttonStyle(.plain).piPointer()
        .opacity(enabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
    }
}
