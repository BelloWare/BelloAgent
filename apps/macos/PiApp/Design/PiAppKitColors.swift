import AppKit

/// The design tokens as AppKit colors, for native views that draw their own
/// rows (the Inspector's outline). The same values as `Color.pi*`, resolved
/// per appearance.
extension NSColor {
    private static func pi(_ light: UInt32, _ lightAlpha: CGFloat = 1, dark: UInt32, _ darkAlpha: CGFloat = 1) -> NSColor {
        func rgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
        }
        return NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? rgb(dark, darkAlpha) : rgb(light, lightAlpha)
        }
    }
    static let piInk = pi(0x1F1B17, dark: 0xF1ECE5)
    static let piInkSecondary = pi(0x6F675E, dark: 0xB0A79C)
    static let piInkTertiary = pi(0x9E958A, dark: 0x7C7469)
    static let piAccent = pi(0x984709, dark: 0xF0A052)
    static let piAccentSoft = pi(0xD67520, 0.12, dark: 0xF0A052, 0.18)
    static let piSuccess = pi(0x3D8A57, dark: 0x7CC48F)
    static let piWarning = pi(0xA8781C, dark: 0xE3B15C)
    static let piDanger = pi(0xC03A3A, dark: 0xEA7C7C)
    static let piInfo = pi(0x4A6FC7, dark: 0x8FAAF0)
    static let piFill = pi(0x000000, 0.045, dark: 0xFFFFFF, 0.05)
    static let piFillStrong = pi(0x000000, 0.075, dark: 0xFFFFFF, 0.09)
    static let piHairline = pi(0x000000, 0.07, dark: 0xFFFFFF, 0.09)
    /// The charts' reasoning purple (`Color.monitorModel(2)`).
    static let piPurple = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.70, green: 0.61, blue: 0.96, alpha: 1) : NSColor(srgbRed: 0.48, green: 0.34, blue: 0.72, alpha: 1)
    }
}
