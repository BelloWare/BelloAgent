// Lays out one reply's Markdown with Swift's own builder, assembler and
// layout manager at a given width, then prints the table geometry and saves
// the drawing: `oracle <markdown-file> <width> <png>`.
import AppKit

let arguments = CommandLine.arguments
let source = try! String(contentsOfFile: arguments[1], encoding: .utf8)
let width = CGFloat(Double(arguments[2])!)
let blocks = TranscriptMarkdown.parse(source, style: .prose)

let output: [String: Any] = MainActor.assumeIsolated {
    let builder = MarkdownTextBuilder()
    let context = MarkdownTextContext(style: .prose, capsWidth: true)
    let text = NSMutableAttributedString()
    var tail: MarkdownTextTail?
    var leadingBreak: String?
    var leadingAttributes: [NSAttributedString.Key: Any] = [:]
    for (index, block) in blocks.enumerated() {
        let identity = MarkdownBlockIdentity(generation: 1, sourceOffset: index)
        let paragraphs = builder.paragraphs(block, identity: identity, context: context,
                                            gap: index == 0 ? 0 : MarkdownTextLayout.blockGap, headingIndex: nil)
        let (part, next) = MarkdownTextAssembler.text(paragraphs, after: tail, leadingBreak: leadingBreak,
                                                       leadingAttributes: leadingAttributes)
        text.append(part)
        tail = next ?? tail
        leadingBreak = paragraphs.last?.breakCopy ?? "\n\n"
        if part.length > 0 {
            leadingAttributes = part.attributes(at: part.length - 1, effectiveRange: nil)
            leadingAttributes[.piBlockBreak] = nil
        }
    }
    let storage = NSTextStorage(attributedString: text)
    let manager = MarkdownTextLayoutManager()
    storage.addLayoutManager(manager)
    let container = NSTextContainer(containerSize: NSSize(width: width, height: .greatestFiniteMagnitude))
    container.lineFragmentPadding = 0
    manager.addTextContainer(container)
    manager.ensureLayout(for: container)
    let used = manager.usedRect(for: container)
    var tables: [[String: Any]] = []
    var cells: [[String: Any]] = []
    let all = NSRange(location: 0, length: storage.length)
    func rect(_ r: NSRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
    if let outline = manager.tableOutline(all) { tables.append(["outline": rect(outline)]) }
    storage.enumerateAttribute(.paragraphStyle, in: all) { value, range, _ in
        guard let style = value as? NSParagraphStyle, let block = style.textBlocks.first as? NSTextTableBlock else { return }
        let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
        let bounds = manager.boundsRect(for: block, glyphRange: glyphs)
        let layout = manager.layoutRect(for: block, glyphRange: glyphs)
        let line = manager.lineFragmentUsedRect(forGlyphAt: glyphs.location, effectiveRange: nil)
        let table = block.table
        let margins = [NSRectEdge.minX, .minY, .maxX, .maxY].map { Double(table.width(for: .margin, edge: $0)) }
        cells.append(["margins": margins, "row": block.startingRow, "column": block.startingColumn,
                      "text": (storage.string as NSString).substring(with: range),
                      "bounds": rect(bounds), "layout": rect(layout), "firstLine": rect(line)])
    }
    var lines: [[String: Any]] = []
    var glyph = 0
    let total = manager.numberOfGlyphs
    while glyph < total {
        var range = NSRange()
        let fragment = manager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: &range)
        let usedLine = manager.lineFragmentUsedRect(forGlyphAt: glyph, effectiveRange: nil)
        let characters = manager.characterRange(forGlyphRange: range, actualGlyphRange: nil)
        let location = manager.location(forGlyphAt: glyph)
        lines.append(["text": (storage.string as NSString).substring(with: characters),
                      "fragment": rect(fragment), "used": rect(usedLine), "baseline": Double(location.y)])
        glyph = NSMaxRange(range)
    }
    // The drawing, on a plain white ground, at 2x.
    let height = ceil(used.maxY) + 20
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(width * 2), pixelsHigh: Int(height * 2),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: width, height: height)
    NSGraphicsContext.saveGraphicsState()
    let graphics = NSGraphicsContext(bitmapImageRep: rep)!
    NSGraphicsContext.current = graphics
    let flip = NSAffineTransform()
    flip.translateX(by: 0, yBy: height); flip.scaleX(by: 1, yBy: -1); flip.concat()
    NSColor.white.setFill(); NSRect(x: 0, y: 0, width: width, height: height).fill()
    let glyphs = manager.glyphRange(for: container)
    // Flipped context for TextKit drawing.
    let flipped = NSGraphicsContext(cgContext: graphics.cgContext, flipped: true)
    NSGraphicsContext.current = flipped
    manager.drawBackground(forGlyphRange: glyphs, at: .zero)
    manager.drawGlyphs(forGlyphRange: glyphs, at: .zero)
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: arguments[3]))
    return ["used": rect(used), "tables": tables, "cells": cells, "lines": lines]
}
let data = try! JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys])
print(String(data: data, encoding: .utf8)!)
