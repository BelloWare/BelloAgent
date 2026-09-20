import SwiftUI
import AppKit

// Shared visual language for the native shell, aligned with Bello Box: cream
// surfaces with a soft orange wash, white cards on hairlines, gradient primary
// actions and tinted icon badges. Colors are dynamic NSColors so light and
// dark appearance resolve automatically.

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

extension Color {
    /// Appearance-aware color built from explicit light and dark values.
    static func piDynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
    }
    /// Application canvas behind the sidebar and sheet chrome: Bello Box cream.
    static let piWindow = piDynamic(light: rgb(0xF6F1EA), dark: rgb(0x1E1B18))
    /// Main content canvas: transcript, editors, sheet bodies.
    static let piContent = piDynamic(light: rgb(0xFCF9F5), dark: rgb(0x26221E))
    /// Raised surfaces: cards, the composer, fields.
    static let piSurface = piDynamic(light: rgb(0xFFFFFF), dark: rgb(0x2E2925))
    static let piSurfaceSunken = piDynamic(light: rgb(0xF7F2EC), dark: rgb(0x211D1A))
    /// The terminal's own canvas. A shell needs to read as a shell: on the
    /// ordinary sunken surface it was two per cent away from the transcript
    /// above it, so the panel looked like more conversation with a
    /// monospaced font. Still cream, clearly a different room.
    static let piTerminalSurface = piDynamic(light: rgb(0xEDE4D8), dark: rgb(0x15120F))
    static let piInk = piDynamic(light: rgb(0x1F1B17), dark: rgb(0xF1ECE5))
    static let piInkSecondary = piDynamic(light: rgb(0x6F675E), dark: rgb(0xB0A79C))
    static let piInkTertiary = piDynamic(light: rgb(0x9E958A), dark: rgb(0x7C7469))
    static let piHairline = piDynamic(light: rgb(0x000000, 0.07), dark: rgb(0xFFFFFF, 0.09))
    static let piHairlineStrong = piDynamic(light: rgb(0x000000, 0.12), dark: rgb(0xFFFFFF, 0.16))
    static let piFill = piDynamic(light: rgb(0x000000, 0.045), dark: rgb(0xFFFFFF, 0.05))
    static let piFillStrong = piDynamic(light: rgb(0x000000, 0.075), dark: rgb(0xFFFFFF, 0.09))
    /// Decorative Bello Box orange; text and action fills use a deeper light
    /// variant so small labels remain readable on cream surfaces.
    static let piBrandOrange = piDynamic(light: rgb(0xD67520), dark: rgb(0xF0A052))
    static let piAccent = piDynamic(light: rgb(0x984709), dark: rgb(0xF0A052))
    static let piAccentSoft = piDynamic(light: rgb(0xD67520, 0.12), dark: rgb(0xF0A052, 0.18))
    static let piOnAccent = piDynamic(light: rgb(0xFFFFFF), dark: rgb(0x1E1B18))
    static let piSuccess = piDynamic(light: rgb(0x3D8A57), dark: rgb(0x7CC48F))
    static let piWarning = piDynamic(light: rgb(0xA8781C), dark: rgb(0xE3B15C))
    static let piDanger = piDynamic(light: rgb(0xC03A3A), dark: rgb(0xEA7C7C))
    static let piInfo = piDynamic(light: rgb(0x4A6FC7), dark: rgb(0x8FAAF0))
    static let piShadow = piDynamic(light: rgb(0x2A2418, 0.09), dark: rgb(0x000000, 0.34))
}

enum PiFont {
    static func display(_ size: CGFloat = 26) -> Font { .system(size: size, weight: .bold) }
    static func title(_ size: CGFloat = 17) -> Font { .system(size: size, weight: .semibold) }
    static let heading = Font.system(size: 14, weight: .semibold)
    static let body = Font.system(size: 13)
    static let captionSize: CGFloat = 11.5
    static let caption = Font.system(size: captionSize)
    static let micro = Font.system(size: 10.5, weight: .medium)
    static let mono = Font.system(size: 12, design: .monospaced)
}

enum PiTone {
    case neutral, accent, success, warning, danger, info
    var color: Color {
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
    static func label(_ state: String, loading: Bool = false) -> String {
        if loading { return "Opening" }
        switch state {
        case "queued": return "Waiting"
        case "running": return "Working"
        case "tool": return "Using a tool"
        case "stopping": return "Stopping"
        case "compacting": return "Compacting"
        case "paused": return "Paused"
        case "interrupted": return "Interrupted"
        case "error", "failed": return "Failed"
        case "idle": return "Ready"
        default: return state.isEmpty ? "" : state.prefix(1).uppercased() + state.dropFirst()
        }
    }
}
