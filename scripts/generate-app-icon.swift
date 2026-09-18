import AppKit
import Foundation

// Package the approved imagegen artwork; this performs resizing only, with
// the source alpha preserved when present. Approved opaque previews are also
// accepted as-is; do not redraw their artwork or invent a transparency mask.
guard CommandLine.arguments.count == 3 else {
    fatalError("Usage: swift scripts/generate-app-icon.swift SOURCE.png DESTINATION.appiconset")
}
let source = URL(fileURLWithPath: CommandLine.arguments[1])
guard let image = NSImage(contentsOf: source),
      let original = NSBitmapImageRep(data: try Data(contentsOf: source)),
      original.pixelsWide == original.pixelsHigh, original.pixelsWide >= 1024 else {
    fatalError("Expected a square PNG of at least 1024 pixels")
}
let destination = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
var images: [[String: String]] = []
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                     isPlanar: false, colorSpaceName: .deviceRGB,
                                     bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(x: 0, y: 0, width: pixels, height: pixels)
        NSGraphicsContext.current?.cgContext.clear(rect)
        image.draw(in: rect, from: .zero, operation: .copy, fraction: 1)
        NSGraphicsContext.restoreGraphicsState()
        let name = "icon_\(size)x\(size)@\(scale)x.png"
        guard let encoded = bitmap.representation(using: .png, properties: [:]),
              let decoded = NSBitmapImageRep(data: encoded), decoded.pixelsWide == pixels, decoded.pixelsHigh == pixels else {
            fatalError("Invalid icon size: \(name)")
        }
        let sourceCorners = [(0, 0), (original.pixelsWide - 1, 0), (0, original.pixelsHigh - 1), (original.pixelsWide - 1, original.pixelsHigh - 1)]
        if original.hasAlpha && sourceCorners.allSatisfy({ original.colorAt(x: $0.0, y: $0.1)?.alphaComponent == 0 }) {
            for point in [(0, 0), (pixels - 1, 0), (0, pixels - 1), (pixels - 1, pixels - 1)] {
                guard decoded.colorAt(x: point.0, y: point.1)?.alphaComponent == 0 else { fatalError("Icon transparency was lost: \(name)") }
            }
        }
        try encoded.write(to: destination.appendingPathComponent(name))
        images.append(["idiom": "mac", "size": "\(size)x\(size)", "scale": "\(scale)x", "filename": name])
    }
}
let data = try JSONSerialization.data(withJSONObject: ["images": images, "info": ["version": 1, "author": "BelloWare"]], options: [.prettyPrinted, .sortedKeys])
try data.write(to: destination.appendingPathComponent("Contents.json"))
