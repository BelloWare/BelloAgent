import AppKit
import XCTest
@testable import PiApp

@MainActor final class TerminalInverseTests: XCTestCase {
    func testIdenticalNormalAndInverseGlyphsContrastInEitherOrderAndAppearance() throws {
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            for inverseFirst in [false, true] {
                let view = TerminalView(emulator: TerminalEmulator(columns: 20, rows: 2))
                view.appearance = NSAppearance(named: appearance)
                view.frame = NSRect(x: 0, y: 0, width: 240, height: 80)
                let styles = inverseFirst ? [7, 0] : [0, 7]
                func feed(_ glyph: String) {
                    view.emulator.feed("\u{1b}[H\u{1b}[?25l\u{1b}[\(styles[0])m\(glyph)\u{1b}[\(styles[1])m\(glyph)\u{1b}[1m \u{1b}[0m")
                    view.refresh()
                }
                feed(" ")
                let blank = try render(view)
                feed("A")
                let drawn = try render(view)
                let width = view.emulator.cellPixelSize.width, height = view.emulator.cellPixelSize.height
                for cell in 0..<2 {
                    var ink = 0
                    for y in 8..<Int(8 + height) { for x in Int(8 + Double(cell) * width)..<Int(8 + Double(cell + 1) * width) {
                        let a = try XCTUnwrap(blank.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        let b = try XCTUnwrap(drawn.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB))
                        if abs(a.redComponent - b.redComponent) + abs(a.greenComponent - b.greenComponent) + abs(a.blueComponent - b.blueComponent) > 0.3 { ink += 1 }
                    } }
                    XCTAssertGreaterThan(ink, 5, "\(appearance.rawValue) inverseFirst=\(inverseFirst) cell=\(cell) must have visible ink")
                }
            }
        }
    }

    private func render(_ view: TerminalView) throws -> NSBitmapImageRep {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(view.bounds.width), pixelsHigh: Int(view.bounds.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 32))
        rep.size = view.bounds.size
        view.effectiveAppearance.performAsCurrentDrawingAppearance { view.cacheDisplay(in: view.bounds, to: rep) }
        return rep
    }
}
