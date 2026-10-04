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
            ("bang11b", .systemFont(ofSize: 11, weight: .bold), .system(size: 11, weight: .bold)),
            ("ended12m", .systemFont(ofSize: 12, weight: .medium), .system(size: 12, weight: .medium)),
            // The work rows and their cards.
            ("title13", .systemFont(ofSize: 13), .system(size: 13)),
            ("summary12.5", .systemFont(ofSize: 12.5), .system(size: 12.5)),
            ("figure11.5", .systemFont(ofSize: 11.5), .system(size: 11.5)),
            ("figure12", .systemFont(ofSize: 12), .system(size: 12)),
            ("gutter11mm", .monospacedSystemFont(ofSize: 11, weight: .medium), .system(size: 11, weight: .medium, design: .monospaced)),
            ("number11.5mono", .monospacedSystemFont(ofSize: 11.5, weight: .regular), .system(size: 11.5, design: .monospaced)),
            ("code12mono", .monospacedSystemFont(ofSize: 12, weight: .regular), .system(size: 12, design: .monospaced))]
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
    /// Every face the native rows wrap text in lands on SwiftUI's pixels and
    /// height, from one line to several.
    @MainActor func testWrappedFacesMatchSwiftUI() throws {
        let sweeping = testEnvironment("PI_TEXT_CALIBRATION") == "1"
        defer { TranscriptPlainTextView.glyphOffsetOverride = nil }
        let faces: [(String, TranscriptPlainTextFace)] = [
            ("detail11.5", TranscriptNativeBranchRow.detailFace), ("note12", TranscriptNativeReplyRow.truncatedFace),
            ("body13", TranscriptNativeFailureRow.bodyFace), ("status12", TranscriptNativeStatusRow.face),
            ("title12.5sb", TranscriptNativeFailureRow.titleFace), ("pill11.5m", TranscriptPillButton.wrappedFace(.systemFont(ofSize: 11.5, weight: .medium))),
            ("code12mono", TranscriptCardFaces.code), ("banner11.5m", TranscriptCardFaces.banner),
            ("note11.5", TranscriptCardFaces.note), ("message12", TranscriptCardFaces.message)]
        var failures: [String] = []
        for (name, face) in faces {
            for n in [0, 1, 2, 3, 5] {
                // None: one short line.
                let text = n == 0 ? "One short line" : String(repeating: "Words that wrap across lines. ", count: n * 2)
                let width: CGFloat = 300
                let host = NSHostingView(rootView: Text(verbatim: text).font(face.font).foregroundStyle(TranscriptPalette.text)
                    .lineSpacing(face.lineSpacing).fixedSize(horizontal: false, vertical: true)
                    .frame(width: width, alignment: .topLeading))
                let swiftHeight = host.fittingSize.height
                let swift = image(host, width: width)
                var results: [(CGFloat, Int)] = []
                var nativeHeight: CGFloat = 0
                for step in (sweeping ? -4...8 : 0...0) {
                    TranscriptPlainTextView.glyphOffsetOverride = sweeping ? CGFloat(step) * 0.125 : nil
                    let view = TranscriptPlainTextView()
                    view.update(text: text, face: face, environment: TranscriptRowEnvironment(), swiftUILines: true)
                    nativeHeight = view.exactHeight(width: width)
                    view.frame = CGRect(x: 0, y: 0, width: width, height: view.measure(width: width).height)
                    results.append((CGFloat(step) * 0.125, TranscriptNativeRowParityTests.difference(swift, image(view, width: width)).0))
                }
                let best = results.min { $0.1 < $1.1 }!
                FileHandle.standardError.write(Data("CALIBRATE wrapped \(name) \(n): SwiftUI \(swiftHeight) native \(nativeHeight); best \(best.0) (\(best.1)); \(results.map { "\($0.0)=\($0.1)" }.joined(separator: " "))\n".utf8))
                if !sweeping, results[0].1 > 0 { failures.append("\(name) \(n): \(results[0].1) px differ") }
                if !sweeping, ceil(nativeHeight) != swiftHeight { failures.append("\(name) \(n): height \(nativeHeight) native, \(swiftHeight) SwiftUI") }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }
    /// Opt-in: how SwiftUI puts a text and a background at fractional places.
    @MainActor func testProbePixelRounding() throws {
        try XCTSkipUnless(testEnvironment("PI_PROBE") == "1")
        for f in stride(from: 0.0, through: 1.0, by: 0.125) {
            let swift = image(NSHostingView(rootView: HStack(spacing: 0) {
                Color.clear.frame(width: 10 + f, height: 1)
                Text("Hello").font(.system(size: 12)).foregroundStyle(Color.black)
                    .padding(.horizontal, 6).background(Color.black.opacity(0.1), in: Capsule())
                Spacer(minLength: 0)
            }.frame(width: 200, height: 20).background(Color.white)), width: 200)
            // Ink columns: first and last column darker than the capsule, and the capsule's own edges.
            var inkFirst = -1, inkLast = -1, bgFirst = -1, bgLast = -1, sum = 0.0, mass = 0.0
            let y = Int(swift.pixelsHigh / 2)
            for x in 0..<swift.pixelsWide {
                guard let color = swift.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                let v = color.redComponent * 255
                if v < 250 { if bgFirst < 0 { bgFirst = x }; bgLast = x }
                if v < 200 { if inkFirst < 0 { inkFirst = x }; inkLast = x }
                for row in 0..<swift.pixelsHigh {
                    let c = swift.colorAt(x: x, y: row)?.usingColorSpace(.deviceRGB)?.redComponent ?? 1
                    let ink = max(0, 0.85 - c); sum += ink * Double(x); mass += ink
                }
            }
            FileHandle.standardError.write(Data("PROBE f=\(f) bg \(bgFirst)...\(bgLast) ink \(inkFirst)...\(inkLast) centroid \(String(format: "%.3f", sum / max(mass, 1)))\n".utf8))
        }
    }
    /// Opt-in: where SwiftUI centres the lines of a text that wraps.
    @MainActor func testProbeCentredLines() throws {
        try XCTSkipUnless(testEnvironment("PI_PROBE") == "1")
        let face = TranscriptNativeStatusRow.face
        let width: CGFloat = 352
        for text in [String(repeating: "The helper restarted after an update and reloaded this chat's settings. ", count: 3), "Model changed to gpt-6.1-sol"] {
            let swift = image(NSHostingView(rootView: Text(verbatim: text).font(face.font).foregroundStyle(TranscriptPalette.text)
                .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                .frame(width: width)), width: width)
            for mode in ["full", "used"] {
                var results: [(CGFloat, Int)] = []
                for step in -6...6 {
                    let view = TranscriptPlainTextView(); view.isSelectable = false; view.centred = true
                    view.update(text: text, face: face, environment: TranscriptRowEnvironment(), swiftUILines: true)
                    let height = view.measure(width: width).height
                    let used = view.usedWidth(width: width)
                    let w = mode == "full" ? width : used
                    let x = (width - w) / 2 + CGFloat(step) * 0.125
                    let canvas = TranscriptNativeRowParityTests.ParityCanvas(frame: CGRect(x: 0, y: 0, width: width, height: height))
                    view.frame = CGRect(x: x, y: 0, width: w, height: height)
                    canvas.addSubview(view)
                    results.append((CGFloat(step) * 0.125, TranscriptNativeRowParityTests.difference(swift, image(canvas, width: width)).0))
                    if step == 0 { FileHandle.standardError.write(Data("PROBE used \(used) exactHeight \(view.exactHeight(width: width))\n".utf8)) }
                }
                FileHandle.standardError.write(Data("PROBE centred \(text.count) \(mode): \(results.map { "\($0.0)=\($0.1)" }.joined(separator: " "))\n".utf8))
            }
        }
    }
    /// The native rows lay a symbol out in the frame SwiftUI gives it: the
    /// table they read matches SwiftUI for every symbol in it.
    @MainActor func testSymbolFramesMatchSwiftUI() throws {
        var failures: [String] = []
        for (key, expected) in TranscriptSymbol.swiftUIFrames {
            let parts = key.split(separator: "/")
            let name = String(parts[0]), size = CGFloat(Double(parts[1])!), weight = CGFloat(Double(parts[2])!)
            let weights: [CGFloat: Font.Weight] = [NSFont.Weight.medium.rawValue: .medium, NSFont.Weight.semibold.rawValue: .semibold,
                                                   NSFont.Weight.bold.rawValue: .bold, 0: .regular]
            SizeProbe.size = .zero
            Self.measureInWindow(SizeProbe { Image(systemName: name).font(.system(size: size, weight: weights[weight] ?? .regular)) })
            FileHandle.standardError.write(Data("CALIBRATE symbol \(key): SwiftUI \(SizeProbe.size)\n".utf8))
            if SizeProbe.size != expected { failures.append("\(key): SwiftUI \(SizeProbe.size), table \(expected)") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }
    @MainActor func testProbeTextHeights() throws {
        try XCTSkipUnless(testEnvironment("PI_PROBE") == "1")
        let faces: [(String, TranscriptPlainTextFace)] = [
            ("detail11.5", TranscriptNativeBranchRow.detailFace), ("note12", TranscriptNativeReplyRow.truncatedFace),
            ("body13", TranscriptNativeFailureRow.bodyFace), ("title12.5sb", TranscriptNativeFailureRow.titleFace),
            ("pill11.5m", TranscriptPillButton.wrappedFace(.systemFont(ofSize: 11.5, weight: .medium))), ("user", .user)]
        for (name, face) in faces {
            for n in [0, 1, 2] {
                let text = n == 0 ? "One short line" : String(repeating: "Words that wrap across lines. ", count: n * 2)
                SizeProbe.size = .zero
                Self.measureInWindow(SizeProbe { Text(verbatim: text).font(face.font).lineSpacing(face.lineSpacing) }.frame(width: 300))
                let view = TranscriptPlainTextView()
                view.update(text: text, face: face, environment: TranscriptRowEnvironment(), swiftUILines: true)
                let plain = SizeProbe.size
                SizeProbe.size = .zero
                Self.measureInWindow(SizeProbe { Text(verbatim: text).font(face.font).lineSpacing(face.lineSpacing).textSelection(.enabled) }.frame(width: 300))
                FileHandle.standardError.write(Data("PROBE text \(name) \(n): selectable \(SizeProbe.size.height) plain \(plain.height)\n".utf8))
                SizeProbe.size = plain
                FileHandle.standardError.write(Data("PROBE text \(name) \(n): SwiftUI \(SizeProbe.size.height) native \(view.exactHeight(width: 300)); width \(SizeProbe.size.width) / \(view.usedWidth(width: 300))\n".utf8))
            }
        }
    }
    /// Opt-in: how close each symbol the native rows draw lands to SwiftUI's
    /// pixels, placed in the middle of SwiftUI's frame for it and nudged.
    @MainActor func testSymbolsDrawAsSwiftUI() throws {
        let sweeping = testEnvironment("PI_TEXT_CALIBRATION") == "1"
        try XCTSkipUnless(sweeping, "calibration sweep: AppKit's symbol renderer is not SwiftUI's")
        defer { TranscriptSymbol.offsetOverride = nil }
        var failures: [String] = []
        let weights: [CGFloat: Font.Weight] = [NSFont.Weight.medium.rawValue: .medium, NSFont.Weight.semibold.rawValue: .semibold,
                                               NSFont.Weight.bold.rawValue: .bold, 0: .regular]
        for key in TranscriptSymbol.swiftUIFrames.keys.sorted() {
            let parts = key.split(separator: "/")
            let name = String(parts[0]), size = CGFloat(Double(parts[1])!), weight = CGFloat(Double(parts[2])!)
            let frame = TranscriptSymbol.swiftUIFrames[key]!
            let swift = image(NSHostingView(rootView: Image(systemName: name).font(.system(size: size, weight: weights[weight] ?? .regular))
                .foregroundStyle(Color.black).padding(.leading, 10).padding(.top, 10).frame(width: 60, height: 40, alignment: .topLeading)), width: 60)
            var results: [(CGPoint, Int)] = []
            let steps = sweeping ? Array(-8...8) : [0]
            for dx in steps { for dy in steps {
                TranscriptSymbol.offsetOverride = sweeping ? CGPoint(x: CGFloat(dx) * 0.125, y: CGFloat(dy) * 0.125) : nil
                let canvas = TranscriptNativeRowParityTests.ParityCanvas(frame: CGRect(x: 0, y: 0, width: 60, height: 40))
                let symbol = TranscriptSymbol()
                symbol.show(name, size: size, weight: NSFont.Weight(weight)); symbol.contentTintColor = .black
                symbol.place(in: CGRect(x: 10, y: 10, width: frame.width, height: frame.height))
                canvas.addSubview(symbol)
                let native = image(canvas, width: 60)
                results.append((TranscriptSymbol.offsetOverride ?? .zero, TranscriptNativeRowParityTests.difference(swift, native).0))
                if let out = testEnvironment("PI_PARITY_OUT"), (TranscriptSymbol.offsetOverride ?? .zero) == .zero {
                    try? TranscriptNativeRowParityTests.png(swift)?.write(to: URL(fileURLWithPath: out + "/symbol-\(name)-swiftui.png"))
                    try? TranscriptNativeRowParityTests.png(native)?.write(to: URL(fileURLWithPath: out + "/symbol-\(name)-native.png"))
                }
            } }
            let best = results.min { $0.1 < $1.1 }!
            FileHandle.standardError.write(Data("CALIBRATE symbol draw \(key): best \(best.0) (\(best.1)); at zero \(results.first { $0.0 == .zero }?.1 ?? -1)\n".utf8))
            // AppKit's symbol renderer is not SwiftUI's: their edges differ by
            // a few hundred pixels of anti-aliasing however they are placed.
            if !sweeping, results[0].1 > 400 { failures.append("\(key): \(results[0].1) px differ") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }
    /// A pill's height comes from SwiftUI's `Label`, which a tall symbol
    /// makes taller than its title by a fraction: the table matches SwiftUI.
    @MainActor func testPillLabelsMatchSwiftUI() throws {
        var failures: [String] = []
        for (symbol, height) in TranscriptPillButton.swiftUILabelHeights {
            SizeProbe.size = .zero
            Self.measureInWindow(SizeProbe { Label("Retry request", systemImage: symbol).font(.system(size: 11.5, weight: .medium)) })
            if abs(SizeProbe.size.height - height) > 0.0001 { failures.append("\(symbol): SwiftUI \(SizeProbe.size.height), table \(height)") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
    }
    @MainActor func testProbeStacks() throws {
        try XCTSkipUnless(testEnvironment("PI_PROBE") == "1")
        for header in [23.0, 23.5, 22.5, 18.5] as [CGFloat] {
            for selectable in [false, true] {
                SizeProbe.size = .zero
                Self.measureInWindow(SizeProbe {
                    VStack(alignment: .leading, spacing: 6) {
                        Color.red.frame(height: header)
                        if selectable { Text("The gateway closed").font(.system(size: 13)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true) }
                        else { Text("The gateway closed").font(.system(size: 13)).fixedSize(horizontal: false, vertical: true) }
                        Text("HTTP 502").font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                    }.padding(.vertical, 10)
                }.frame(width: 300))
                FileHandle.standardError.write(Data("PROBE stack header \(header) selectable \(selectable): \(SizeProbe.size.height)\n".utf8))
            }
        }
        for header in [23.5, 22.5] as [CGFloat] {
            SizeProbe.size = .zero
            Self.measureInWindow(SizeProbe { HStack(spacing: 8) { Color.red.frame(width: 10, height: 18); Spacer(minLength: 0); Color.blue.frame(width: 10, height: header) } }.frame(width: 300))
            FileHandle.standardError.write(Data("PROBE hstack \(header): \(SizeProbe.size.height)\n".utf8))
            SizeProbe.size = .zero
            Self.measureInWindow(SizeProbe { Button(action: {}) { Label("Retry request", systemImage: "arrow.clockwise").font(.system(size: 11.5, weight: .medium)) }.buttonStyle(TranscriptPillStyle(accent: true)) }.frame(width: 300))
            FileHandle.standardError.write(Data("PROBE retry pill: \(SizeProbe.size)\n".utf8))
            SizeProbe.size = .zero
            Self.measureInWindow(SizeProbe { Label("Retry request", systemImage: "arrow.clockwise").font(.system(size: 11.5, weight: .medium)) }.frame(width: 300))
            FileHandle.standardError.write(Data("PROBE retry label: \(SizeProbe.size)\n".utf8))
            SizeProbe.size = .zero
            Self.measureInWindow(SizeProbe { Label("Raise limit…", systemImage: "arrow.up.circle").font(.system(size: 11.5, weight: .medium)) }.frame(width: 300))
            FileHandle.standardError.write(Data("PROBE raise label: \(SizeProbe.size)\n".utf8))
            SizeProbe.size = .zero
            Self.measureInWindow(SizeProbe { Label("Continue", systemImage: "play.fill").font(.system(size: 11.5, weight: .medium)) }.frame(width: 300))
            FileHandle.standardError.write(Data("PROBE continue label: \(SizeProbe.size)\n".utf8))
        }
    }
    @MainActor func testProbeHostRounding() throws {
        try XCTSkipUnless(testEnvironment("PI_PROBE") == "1")
        for h in [10.1, 10.25, 10.4, 10.5, 10.6, 10.75, 11.5, 12.5, 90.5] as [CGFloat] {
            let host = NSHostingView(rootView: Color.clear.frame(width: 10, height: h).fixedSize())
            host.sizingOptions = [.intrinsicContentSize]
            host.layoutSubtreeIfNeeded()
            FileHandle.standardError.write(Data("PROBE host \(h): intrinsic \(host.intrinsicContentSize.height) fitting \(host.fittingSize.height)\n".utf8))
        }
    }
    @MainActor func testSweepGlyphOffsets() throws {
        try XCTSkipUnless(testEnvironment("PI_TEXT_CALIBRATION") == "1", "calibration sweep")
        try sweep(steps: 0...8)
    }
    /// The user's text lands on SwiftUI's pixels at every number of lines:
    /// where SwiftUI sets its glyphs depends on how far the text's height is
    /// from a whole point, which changes line by line.
    @MainActor func testUserTextAtEveryLineCount() throws {
        let sweeping = testEnvironment("PI_TEXT_CALIBRATION") == "1"
        defer { TranscriptPlainTextView.glyphOffsetOverride = nil }
        let face = TranscriptPlainTextFace.user, width: CGFloat = 300
        var failures: [String] = []
        for n in 1...14 {
            let text = String(repeating: "Words that wrap across lines. ", count: n)
            let swift = image(NSHostingView(rootView: Text(verbatim: text).font(face.font).foregroundStyle(TranscriptPalette.text)
                .lineSpacing(face.lineSpacing).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
                .frame(width: width, alignment: .leading)), width: width)
            var results: [(CGFloat, Int)] = []
            for step in (sweeping ? -4...12 : 0...0) {
                TranscriptPlainTextView.glyphOffsetOverride = sweeping ? CGFloat(step) * 0.125 : nil
                let view = TranscriptPlainTextView()
                view.update(text: text, face: face, environment: TranscriptRowEnvironment(), swiftUILines: true)
                view.frame = CGRect(x: 0, y: 0, width: width, height: view.measure(width: width).height)
                results.append((CGFloat(step) * 0.125, TranscriptNativeRowParityTests.difference(swift, image(view, width: width)).0))
            }
            FileHandle.standardError.write(Data("CALIBRATE user \(n)x: \(results.map { "\($0.0)=\($0.1)" }.joined(separator: " "))\n".utf8))
            if !sweeping, results[0].1 > 0 { failures.append("\(n)x: \(results[0].1) px differ") }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "; "))
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
    /// Lays `view` out in a window, at the screen's own scale: SwiftUI rounds
    /// sizes to the pixels of the window it is in.
    @MainActor static func measureInWindow<V: View>(_ view: V) {
        let host = NSHostingView(rootView: view)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 400, height: 200), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        window.contentView = nil
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

/// Records the exact size SwiftUI gives its one subview, unrounded.
struct SizeProbe: Layout {
    nonisolated(unsafe) static var size = CGSize.zero
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let size = subviews.first?.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil)) ?? .zero
        Self.size = size
        return size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: nil))
    }
}
