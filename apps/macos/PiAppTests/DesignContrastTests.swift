import AppKit
import SwiftUI
import XCTest
@testable import PiApp

final class DesignContrastTests: XCTestCase {
    private struct RGB {
        let r: Double, g: Double, b: Double
        func blend(_ other: RGB, fraction: Double) -> RGB {
            RGB(r: r + (other.r - r) * fraction, g: g + (other.g - g) * fraction, b: b + (other.b - b) * fraction)
        }
        var luminance: Double {
            func linear(_ value: Double) -> Double { value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4) }
            return 0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
        }
        func contrast(with other: RGB) -> Double {
            (max(luminance, other.luminance) + 0.05) / (min(luminance, other.luminance) + 0.05)
        }
    }

    @MainActor private func resolved(_ color: Color, appearance: NSAppearance) throws -> RGB {
        var result: NSColor?
        appearance.performAsCurrentDrawingAppearance { result = NSColor(color).usingColorSpace(.sRGB) }
        let value = try XCTUnwrap(result)
        return RGB(r: value.redComponent, g: value.greenComponent, b: value.blueComponent)
    }

    @MainActor func testAccentLabelsAndLinksRemainReadableInBothAppearances() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let accent = try resolved(.piAccent, appearance: appearance)
            for surface in [Color.piWindow, .piContent, .piSurface, .piSurfaceSunken] {
                let background = try resolved(surface, appearance: appearance)
                XCTAssertGreaterThanOrEqual(accent.contrast(with: background), 4.5, "Small accent text on \(name)")
                // Accent badges place small labels over a 13% tint.
                XCTAssertGreaterThanOrEqual(accent.contrast(with: background.blend(accent, fraction: 0.13)), 4.5, "Tinted badge on \(name)")
            }
        }
    }

    /// Primary pills are flat brand orange with bold white labels; the bold
    /// large-text threshold applies, including the hover and pressed shades.
    @MainActor func testPrimaryLabelsRetainContrastAcrossInteractionStates() throws {
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            let appearance = try XCTUnwrap(NSAppearance(named: name))
            let foreground = try resolved(.piOnAccent, appearance: appearance)
            let background = try resolved(.piBrandOrange, appearance: appearance)
            for shade in [0.0, 0.05, 0.10] {
                let shaded = background.blend(RGB(r: 0, g: 0, b: 0), fraction: shade)
                XCTAssertGreaterThanOrEqual(foreground.contrast(with: shaded), 3.0, "Enabled primary label on \(name), shade \(shade)")
            }
            XCTAssertGreaterThanOrEqual(foreground.contrast(with: try resolved(.piDanger, appearance: appearance)), 4.5, "Stop icon on \(name)")
        }
    }
}
