import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// Finds, for each face the native rows set text in, how far TextKit's glyphs
/// must be raised to land on SwiftUI's: draws a selectable SwiftUI `Text` and
/// a `TranscriptPlainTextView` at the same place and sweeps the offset.
/// Opt-in (`PI_TEXT_CALIBRATION=1`); prints `CALIBRATE` lines.
final class TranscriptTextCalibrationTests: XCTestCase {
    /// Every face, one line and wrapped, lands on SwiftUI's pixels with the
    /// offsets `TranscriptPlainTextView.glyphOffset` gives it.
    @MainActor func testTheOffsetTableMatchesSwiftUI() throws { try sweep(steps: nil) }
    /// The labels' one line, as a non-selectable SwiftUI `Text` sets it.
    @MainActor func testLabelsMatchSwiftUI() throws {
        let fonts: [(String, NSFont, Font)] = [
            ("title12.5sb", .systemFont(ofSize: 12.5, weight: .semibold), .system(size: 12.5, weight: .semibold)),
            ("clock10.5", .systemFont(ofSize: 10.5), .system(size: 10.5)),
            ("pill11m", .systemFont(ofSize: 11, weight: .medium), .system(size: 11, weight: .medium)),
            ("pill11.5m", .systemFont(ofSize: 11.5, weight: .medium), .system(size: 11.5, weight: .medium)),
            ("bang11b", .systemFont(ofSize: 11, weight: .bold), .system(size: 11, weight: .bold))]
        let sweeping = testEnvironment("PI_TEXT_CALIBRATION") == "1"
        defer { TranscriptLabel.baselineOverride = nil }
        var failures: [String] = []
        for (name, nsFont, font) in fonts {
            let text = "Retry request 12:41"
            let swift = image(NSHostingView(rootView: Text(verbatim: text).font(font).foregroundStyle(TranscriptPalette.text).fixedSize()
                .frame(maxWidth: .infinity, alignment: .topLeading)), width: 200)
            let measured = NSHostingView(rootView: Text(verbatim: text).font(font).fixedSize()).fittingSize.height
            FileHandle.standardError.write(Data("CALIBRATE line \(name): SwiftUI \(measured), label \(TranscriptLabel.lineHeight(nsFont)), ascender \(nsFont.ascender) descender \(nsFont.descender) leading \(nsFont.leading)\n".utf8))
            var results: [(CGFloat, Int)] = []
            for step in (sweeping ? -4...4 : 0...0) {
                TranscriptLabel.baselineOverride = sweeping ? CGFloat(step) * 0.25 : nil
                let label = TranscriptLabel(); label.text = text; label.font = nsFont; label.color = TranscriptNSPalette.text
                label.frame = CGRect(origin: .zero, size: label.intrinsicSize)
                let native = image(label, width: 200)
                results.append((CGFloat(step) * 0.25, TranscriptNativeRowParityTests.difference(swift, native).0))
                if let out = testEnvironment("PI_PARITY_OUT"), step == 0 {
                    try? TranscriptNativeRowParityTests.png(swift)?.write(to: URL(fileURLWithPath: out + "/label-\(name)-swiftui.png"))
                    try? TranscriptNativeRowParityTests.png(native)?.write(to: URL(fileURLWithPath: out + "/label-\(name)-native.png"))
                }
            }
            FileHandle.standardError.write(Data("CALIBRATE label \(name): \(results.map { "\($0.0)=\($0.1)" }.joined(separator: " "))\n".utf8))
            if !sweeping, results[0].1 > 0 { failures.append("\(name): \(results[0].1) px differ") }
            if !sweeping, TranscriptLabel.measured(nsFont) == nil { failures.append("\(name): not in the measured table") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }
    @MainActor func testSweepGlyphOffsets() throws {
        try XCTSkipUnless(testEnvironment("PI_TEXT_CALIBRATION") == "1", "calibration sweep")
        try sweep(steps: 0...8)
    }
    @MainActor private func sweep(steps: ClosedRange<Int>?) throws {
        let faces: [(String, TranscriptPlainTextFace)] = [
            ("user", .user), ("source", .source), ("body13", TranscriptNativeFailureRow.bodyFace),
            ("detail12", TranscriptNativeFailureRow.detailFace)]
        let texts = [("one", "One short line of text"),
                     ("wrapped", String(repeating: "Words that wrap across several lines of the text. ", count: 5))]
        defer { TranscriptPlainTextView.glyphOffsetOverride = nil }
        for (name, face) in faces {
            for (kind, text) in texts {
                let width: CGFloat = 300
                let swift = image(NSHostingView(rootView: Text(verbatim: text).font(face.font).foregroundStyle(TranscriptPalette.text)
                    .lineSpacing(face.lineSpacing).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                    .frame(width: width, alignment: .leading)), width: width)
                var results: [(CGFloat, Int)] = []
                for step in steps ?? 0...0 {
                    let offset = CGFloat(step) * 0.25
                    TranscriptPlainTextView.glyphOffsetOverride = steps == nil ? nil : offset
                    let view = TranscriptPlainTextView()
                    view.update(text: text, face: face, environment: TranscriptRowEnvironment(), swiftUILines: true)
                    let height = view.measure(width: width).height
                    view.frame = CGRect(x: 0, y: 0, width: width, height: height)
                    results.append((offset, TranscriptNativeRowParityTests.difference(swift, image(view, width: width)).0))
                }
                let best = results.min { $0.1 < $1.1 }!
                FileHandle.standardError.write(Data("CALIBRATE \(name) \(kind): best \(best.0) (\(best.1) px); \(results.map { "\($0.0)=\($0.1)" }.joined(separator: " "))\n".utf8))
                if steps == nil { XCTAssertEqual(best.1, 0, "\(name) \(kind) lands on SwiftUI's pixels") }
            }
        }
    }
    @MainActor private func image(_ view: NSView, width: CGFloat) -> NSBitmapImageRep {
        let height = max(1, ceil(view.fittingSize.height > 0 ? view.fittingSize.height : view.frame.height))
        let canvas = TranscriptNativeRowParityTests.ParityCanvas(frame: CGRect(x: 0, y: 0, width: width, height: height))
        canvas.wantsLayer = true; canvas.layer?.backgroundColor = NSColor.white.cgColor
        let window = NSWindow(contentRect: canvas.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: .aqua)
        window.contentView = canvas
        view.frame = CGRect(x: 0, y: 0, width: width, height: height)
        canvas.addSubview(view)
        canvas.layoutSubtreeIfNeeded(); view.layoutSubtreeIfNeeded(); canvas.display()
        let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        window.contentView = nil
        return rep
    }
}
