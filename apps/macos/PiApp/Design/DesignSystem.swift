import SwiftUI
import AppKit

// The shared visual language in SwiftUI's terms. The tokens themselves —
// colors, spacing, radii, tones — are AppKit's (DesignKit/PiKitTokens.swift);
// this file reads them as SwiftUI colors and fonts while SwiftUI views remain.

extension Color {
    /// Appearance-aware color built from explicit light and dark values.
    static func piDynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }
    // The tokens themselves are AppKit's (`NSColor.pi*`, DesignKit/PiKitTokens.swift):
    // one dynamic color per token, read here as SwiftUI colors.
    static let piWindow = Color(nsColor: .piWindow)
    static let piContent = Color(nsColor: .piContent)
    static let piSurface = Color(nsColor: .piSurface)
    static let piSurfaceSunken = Color(nsColor: .piSurfaceSunken)
    static let piTerminalSurface = Color(nsColor: .piTerminalSurface)
    static let piInk = Color(nsColor: .piInk)
    static let piInkSecondary = Color(nsColor: .piInkSecondary)
    static let piInkTertiary = Color(nsColor: .piInkTertiary)
    static let piHairline = Color(nsColor: .piHairline)
    static let piHairlineStrong = Color(nsColor: .piHairlineStrong)
    static let piFill = Color(nsColor: .piFill)
    static let piFillStrong = Color(nsColor: .piFillStrong)
    static let piBrandOrange = Color(nsColor: .piBrandOrange)
    static let piAccent = Color(nsColor: .piAccent)
    static let piAccentSoft = Color(nsColor: .piAccentSoft)
    static let piOnAccent = Color(nsColor: .piOnAccent)
    static let piSuccess = Color(nsColor: .piSuccess)
    static let piWarning = Color(nsColor: .piWarning)
    static let piDanger = Color(nsColor: .piDanger)
    static let piInfo = Color(nsColor: .piInfo)
    static let piShadow = Color(nsColor: .piShadow)
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

extension PiTone {
    var color: Color { Color(nsColor: nsColor) }
}
