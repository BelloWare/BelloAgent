import AppKit
import Foundation

// Draws the Bello Agent artwork with Core Graphics so the icon can be
// regenerated deterministically. Style follows the BelloBox and Clipboard
// icons: a warm cream tile, one illustrated object in BelloWare terracotta,
// and the "Bello" wordmark. Output is a 1024 px square PNG with alpha.
// Usage: swift scripts/draw-app-icon.swift DESTINATION.png

guard CommandLine.arguments.count == 2 else { fatalError("Usage: swift scripts/draw-app-icon.swift DESTINATION.png") }
let destination = URL(fileURLWithPath: CommandLine.arguments[1])
let pixels = 1024
let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                              hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
let context = NSGraphicsContext.current!.cgContext
context.clear(CGRect(x: 0, y: 0, width: pixels, height: pixels))

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255, green: CGFloat((hex >> 8) & 0xff) / 255, blue: CGFloat(hex & 0xff) / 255, alpha: alpha)
}
func gradient(_ colors: [CGColor]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: nil)!
}

// Tile: the macOS icon grid leaves roughly 10% transparent margin.
let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
let tilePath = CGPath(roundedRect: tile, cornerWidth: 186, cornerHeight: 186, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 40, color: rgb(0x3A2418, 0.28))
context.addPath(tilePath); context.setFillColor(rgb(0xF6E8D3)); context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(tilePath); context.clip()
context.drawLinearGradient(gradient([rgb(0xFBF1E2), rgb(0xF1DDC3)]), start: CGPoint(x: 0, y: tile.maxY), end: CGPoint(x: 0, y: tile.minY), options: [])
// Soft highlight in the upper left of the tile.
context.drawRadialGradient(gradient([rgb(0xFFFFFF, 0.55), rgb(0xFFFFFF, 0)]), startCenter: CGPoint(x: 300, y: 860), startRadius: 0, endCenter: CGPoint(x: 300, y: 860), endRadius: 520, options: [])
context.restoreGState()

// Speech bubble body with a tail at the lower left.
let bubble = CGRect(x: 178, y: 300, width: 668, height: 520)
let bubblePath = CGMutablePath()
bubblePath.addRoundedRect(in: bubble, cornerWidth: 150, cornerHeight: 150)
bubblePath.move(to: CGPoint(x: 300, y: 318))
bubblePath.addLine(to: CGPoint(x: 236, y: 214))
bubblePath.addQuadCurve(to: CGPoint(x: 420, y: 306), control: CGPoint(x: 330, y: 260))
bubblePath.closeSubpath()
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -18), blur: 36, color: rgb(0x8A3A1E, 0.35))
context.addPath(bubblePath); context.setFillColor(rgb(0xC9582F)); context.fillPath()
context.restoreGState()
context.saveGState()
context.addPath(bubblePath); context.clip()
context.drawLinearGradient(gradient([rgb(0xD96A3F), rgb(0xB84C27)]), start: CGPoint(x: 0, y: bubble.maxY), end: CGPoint(x: 0, y: bubble.minY), options: [])
// Glossy rim along the top edge.
context.drawLinearGradient(gradient([rgb(0xFFFFFF, 0.22), rgb(0xFFFFFF, 0)]), start: CGPoint(x: 0, y: bubble.maxY), end: CGPoint(x: 0, y: bubble.maxY - 160), options: [])
context.restoreGState()

// Antenna.
context.setFillColor(rgb(0xB84C27))
context.fill(CGRect(x: 500, y: 812, width: 24, height: 62))
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -6), blur: 12, color: rgb(0x8A3A1E, 0.3))
context.setFillColor(rgb(0xF6C36A))
context.fillEllipse(in: CGRect(x: 478, y: 856, width: 68, height: 68))
context.restoreGState()
context.setFillColor(rgb(0xFFFFFF, 0.55))
context.fillEllipse(in: CGRect(x: 494, y: 884, width: 22, height: 22))

// Face: two eyes and a smile, in cream.
let cream = rgb(0xFBF2E6)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -4), blur: 8, color: rgb(0x6B2A14, 0.25))
context.setFillColor(cream)
for x in [368, 582] {
    context.addPath(CGPath(roundedRect: CGRect(x: x, y: 640, width: 74, height: 112), cornerWidth: 37, cornerHeight: 37, transform: nil))
}
context.fillPath()
context.restoreGState()
context.saveGState()
context.setStrokeColor(cream); context.setLineWidth(30); context.setLineCap(.round)
context.addArc(center: CGPoint(x: 512, y: 650), radius: 92, startAngle: .pi * 1.16, endAngle: .pi * 1.84, clockwise: false)
context.strokePath()
context.restoreGState()

// Wordmark.
let paragraph = NSMutableParagraphStyle(); paragraph.alignment = .center
let font = NSFont.systemFont(ofSize: 150, weight: .heavy)
let descriptor = font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor
let rounded = NSFont(descriptor: descriptor, size: 150) ?? font
let attributes: [NSAttributedString.Key: Any] = [.font: rounded, .foregroundColor: NSColor(cgColor: cream)!, .paragraphStyle: paragraph, .kern: -4]
let text = NSAttributedString(string: "Bello", attributes: attributes)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -5), blur: 10, color: rgb(0x6B2A14, 0.3))
text.draw(in: CGRect(x: bubble.minX, y: 330, width: bubble.width, height: 180))
context.restoreGState()

NSGraphicsContext.restoreGraphicsState()
guard let png = bitmap.representation(using: .png, properties: [:]) else { fatalError("PNG encoding failed") }
try png.write(to: destination, options: .atomic)
print("Wrote \(destination.path)")
