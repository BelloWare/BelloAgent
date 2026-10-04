import AppKit

// The shared visual language, aligned with Bello Box: cream surfaces with a
// soft orange wash, white cards on hairlines, flat brand-orange primary
// actions and tinted icon badges. Every token is a dynamic NSColor, so light
// and dark appearance resolve wherever it is drawn; SwiftUI reads the same
// objects (`Color.pi*`, Design/DesignSystem.swift).

enum PiSpacing {
    static let xs: CGFloat = 4
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 24
}

enum PiRadius {
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 22
}

extension NSColor {
    /// An appearance-aware color from explicit light and dark values.
    static func piDynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }
    private static func pi(_ light: UInt32, _ lightAlpha: CGFloat = 1, dark: UInt32, _ darkAlpha: CGFloat = 1) -> NSColor {
        func rgb(_ hex: UInt32, _ alpha: CGFloat) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
        }
        return piDynamic(light: rgb(light, lightAlpha), dark: rgb(dark, darkAlpha))
    }
    /// Application canvas behind the sidebar and sheet chrome: Bello Box cream.
    static let piWindow = pi(0xF6F1EA, dark: 0x1E1B18)
    /// Main content canvas: transcript, editors, sheet bodies.
    static let piContent = pi(0xFCF9F5, dark: 0x26221E)
    /// Raised surfaces: cards, the composer, fields.
    static let piSurface = pi(0xFFFFFF, dark: 0x2E2925)
    static let piSurfaceSunken = pi(0xF7F2EC, dark: 0x211D1A)
    /// The terminal's own canvas. A shell needs to read as a shell: on the
    /// ordinary sunken surface it was two per cent away from the transcript
    /// above it, so the panel looked like more conversation with a
    /// monospaced font. Still cream, clearly a different room.
    static let piTerminalSurface = pi(0xEDE4D8, dark: 0x15120F)
    static let piInk = pi(0x1F1B17, dark: 0xF1ECE5)
    static let piInkSecondary = pi(0x6F675E, dark: 0xB0A79C)
    static let piInkTertiary = pi(0x9E958A, dark: 0x7C7469)
    static let piHairline = pi(0x000000, 0.07, dark: 0xFFFFFF, 0.09)
    static let piHairlineStrong = pi(0x000000, 0.12, dark: 0xFFFFFF, 0.16)
    static let piFill = pi(0x000000, 0.045, dark: 0xFFFFFF, 0.05)
    static let piFillStrong = pi(0x000000, 0.075, dark: 0xFFFFFF, 0.09)
    /// Decorative Bello Box orange; text and action fills use a deeper light
    /// variant so small labels remain readable on cream surfaces.
    static let piBrandOrange = pi(0xD67520, dark: 0xF0A052)
    static let piAccent = pi(0x984709, dark: 0xF0A052)
    static let piAccentSoft = pi(0xD67520, 0.12, dark: 0xF0A052, 0.18)
    static let piOnAccent = pi(0xFFFFFF, dark: 0x1E1B18)
    static let piSuccess = pi(0x3D8A57, dark: 0x7CC48F)
    static let piWarning = pi(0xA8781C, dark: 0xE3B15C)
    static let piDanger = pi(0xC03A3A, dark: 0xEA7C7C)
    static let piInfo = pi(0x4A6FC7, dark: 0x8FAAF0)
    static let piShadow = pi(0x2A2418, 0.09, dark: 0x000000, 0.34)
    /// Selected text in the Inspector's whole texts: the brand orange, soft
    /// enough for the ink to read through.
    static let piTextSelection = pi(0xD67520, 0.26, dark: 0xF0A052, 0.32)
    /// The charts' reasoning purple (`Color.monitorModel(2)`).
    static let piPurple = NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? NSColor(srgbRed: 0.70, green: 0.61, blue: 0.96, alpha: 1) : NSColor(srgbRed: 0.48, green: 0.34, blue: 0.72, alpha: 1)
    }
}

enum PiTone {
    case neutral, accent, success, warning, danger, info
    var nsColor: NSColor {
        switch self {
        case .neutral: return .piInkSecondary
        case .accent: return .piAccent
        case .success: return .piSuccess
        case .warning: return .piWarning
        case .danger: return .piDanger
        case .info: return .piInfo
        }
    }
}

/// What a run's state is called on screen. The helper reports its own words —
/// `queued`, `compacting`, `tool` — and those words were reaching the sidebar
/// unchanged, so a chat that was simply waiting its turn said "queued" and a
/// chat the reader had stopped said "paused". A state is a word the reader
/// knows, and it is the same word the live turn bar uses above the composer,
/// so one chat does not have two vocabularies.
enum PiSessionState {
    /// The label for a run state. `loading` is a chat whose helper session is
    /// still being opened, which the helper does not have a state for.
    static func label(_ state: String, loading: Bool = false, costLimited: Bool = false) -> String {
        if loading { return "Opening" }
        switch state {
        case "queued": return "Waiting"
        case "running": return "Working"
        case "tool": return "Working"
        case "stopping": return "Stopping"
        case "compacting": return "Compacting"
        case "paused": return "Paused"
        case "interrupted": return "Interrupted"
        case "error", "failed": return costLimited ? "Stopped · cost limit" : "Failed"
        case "idle": return "Ready"
        default: return state.isEmpty ? "" : state.prefix(1).uppercased() + state.dropFirst()
        }
    }
}

/// The AppKit Pi components (DesignKit/), named in one place so they never
/// collide with the SwiftUI ones they replace.
enum PiKit {
    /// The type scale, as `PiFont` gives it to SwiftUI.
    enum Font {
        static func display(_ size: CGFloat = 26) -> NSFont { .systemFont(ofSize: size, weight: .bold) }
        static func title(_ size: CGFloat = 17) -> NSFont { .systemFont(ofSize: size, weight: .semibold) }
        static var heading: NSFont { .systemFont(ofSize: 14, weight: .semibold) }
        static var body: NSFont { .systemFont(ofSize: 13) }
        static let captionSize: CGFloat = 11.5
        static var caption: NSFont { .systemFont(ofSize: captionSize) }
        static var micro: NSFont { .systemFont(ofSize: 10.5, weight: .medium) }
        static var mono: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }
        /// A font with monospaced digits, as `.monospacedDigit()` gives text.
        static func monospacedDigits(_ font: NSFont) -> NSFont {
            let descriptor = font.fontDescriptor.addingAttributes([.featureSettings: [[
                NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector]]])
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }
    }
}
