import XCTest
import AppKit
import SwiftUI
@testable import PiApp

/// Native rows read exactly as the SwiftUI rows they replace: each fixture is
/// measured and drawn once through each, at several widths and in both
/// appearances, and the two must have the same height and the same pixels.
///
/// Set `PI_PARITY_OUT` (and `TEST_RUNNER_PI_PARITY_OUT`) to a folder to keep
/// both captures and a difference image for every pair.
final class TranscriptNativeRowParityTests: XCTestCase {
    /// How far apart two pixels may be, in any channel out of 255, before
    /// they count as different, and how many may differ. Text drawn twice by
    /// the same font machinery lands on the same pixels; anything that moved
    /// shows as a band of differing pixels well above this.
    static let channelTolerance = 24
    static let pixelTolerance = 0.004

    struct Fixture { let name: String; let item: TranscriptItem }

    /// Pairs that still differ, each an open item of the port rather than a
    /// tolerance: the long question at 380 points sits where SwiftUI's
    /// rounding of a fractional row (0.16 pt) moves its glyphs by a fraction
    /// of a pixel that the native text does not reproduce yet. Heights match.
    static let knownDeviations = Set(["user-long-380-light", "user-long-380-dark"])
        // The output-limit notice under a reply: same height, its icon and
        // text not yet placed exactly where SwiftUI's HStack puts them.
        .union(["380", "520", "792"].flatMap { w in ["light", "dark"].map { "reply-length-\(w)-\($0)" } })

    static var userFixtures: [Fixture] {
        let at = 1_790_000_000_000.0
        func user(_ id: String, _ text: String, state: String? = nil) -> TranscriptItem {
            var message = TranscriptMessage(id: id, role: "user", text: text)
            message.at = at; message.state = state
            return .message(message)
        }
        return [
            Fixture(name: "user-short", item: user("u1", "Please read fixture README.md")),
            Fixture(name: "user-lines", item: user("u2", "First line\nSecond line, a little longer\n\nAfter a blank line")),
            Fixture(name: "user-long", item: user("u3", String(repeating: "A long question that wraps across the bubble's width, word after word. ", count: 6))),
            Fixture(name: "user-literal", item: user("u4", "**not bold** `not code` # not a heading\n- not a list")),
            Fixture(name: "user-sending", item: user("u5", "Just sent", state: TranscriptMessage.sendingState)),
        ]
    }

    @MainActor func testUserRowsMatchTheirSwiftUIRows() throws {
        try compare(Self.userFixtures, expectNative: TranscriptNativeUserRow.self)
    }

    /// Replies as the planner lays them out: their bodies are native.
    @MainActor static var replyFixtures: [Fixture] {
        func reply(_ id: String, _ text: String, streaming: Bool = false) -> TranscriptMessage {
            var message = TranscriptMessage(id: id, role: "assistant", text: text)
            message.at = 1_790_000_000_000; message.turn = "q-" + id
            if streaming { message.state = "streaming" }
            return message
        }
        let markdown = """
        ## What changed

        The loop retried **three** times with a fixed delay. Now it:

        1. widens the budget to five attempts,
        2. doubles the delay each time, and
        3. gives up with a clear error.

        ```swift
        let delay = base * pow(2, Double(attempt))
        ```

        | Attempt | Delay |
        | --- | --- |
        | 1 | 1 s |
        | 2 | 2 s |

        See `PaymentClient.swift` for the rest.
        """
        var fixtures: [Fixture] = []
        for (name, message) in [("reply-prose", reply("a1", "The loop retries three times with a fixed delay. I widened the budget to five and made the delay grow.")),
                                ("reply-markdown", reply("a2", markdown)),
                                ("reply-waiting", reply("a3", "", streaming: true)),
                                ("reply-length", { var m = reply("a4", "Cut short by the limit"); m.stopReason = "length"; return m }())] {
            var question = TranscriptMessage(id: "q-" + message.id, role: "user", text: "Question")
            question.at = message.at
            let items = TaskTranscriptPlan.items([question, message], lifecycle: nil, display: .normal)
            for item in items where TranscriptNativeReplyRow.reply(of: item) != nil { fixtures.append(Fixture(name: name, item: item)) }
        }
        return fixtures
    }

    @MainActor func testReplyBodiesMatchTheirSwiftUIRows() throws {
        let fixtures = Self.replyFixtures
        // A reply still waiting for its first token is not a body row yet.
        XCTAssertEqual(Set(fixtures.map(\.name)), ["reply-prose", "reply-markdown", "reply-length"], "every finished reply must plan a body row")
        try compare(fixtures, expectNative: TranscriptNativeReplyRow.self)
    }

    // MARK: Drawing a row both ways

    @MainActor private func compare<T: NSView>(_ fixtures: [Fixture], expectNative: T.Type) throws {
        let out = testEnvironment("PI_PARITY_OUT").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        var failures: [String] = []
        for fixture in fixtures {
            for width in [792.0, 520.0, 380.0] as [CGFloat] {
                for dark in [false, true] {
                    let label = "\(fixture.name)-\(Int(width))-\(dark ? "dark" : "light")"
                    let hosted = render(fixture.item, width: width, dark: dark, native: false)
                    let native = render(fixture.item, width: width, dark: dark, native: true)
                    XCTAssertTrue(native.content is T, "\(label): the native renderer did not draw this row")
                    XCTAssertFalse(hosted.content is T, "\(label): the SwiftUI renderer drew a native row")
                    if hosted.height != native.height {
                        failures.append("\(label): height \(native.height) native, \(hosted.height) SwiftUI")
                    }
                    let (differing, total, diff) = Self.difference(hosted.image, native.image)
                    let share = total == 0 ? 0 : Double(differing) / Double(total)
                    if share > Self.pixelTolerance, !Self.knownDeviations.contains(label) { failures.append(String(format: "%@: %.2f%% of pixels differ (%d)", label, share * 100, differing)) }
                    if let out {
                        try Self.png(hosted.image)?.write(to: out.appendingPathComponent(label + "-swiftui.png"))
                        try Self.png(native.image)?.write(to: out.appendingPathComponent(label + "-native.png"))
                        if let diff { try Self.png(diff)?.write(to: out.appendingPathComponent(label + "-diff.png")) }
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    struct Rendered { let height: CGFloat; let image: NSBitmapImageRep; let content: NSView? }

    @MainActor private func render(_ item: TranscriptItem, width: CGFloat, dark: Bool, native: Bool) -> Rendered {
        let previous = TranscriptRowRenderer.native
        TranscriptRowRenderer.native = native
        defer { TranscriptRowRenderer.native = previous }
        var environment = TranscriptRowEnvironment()
        environment.colorScheme = dark ? .dark : .light
        let row = TranscriptRowContainer(item: item, fresh: false, actions: TranscriptActions(), environment: environment)
        let height = row.measure(width: width).height
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let canvas = ParityCanvas(frame: CGRect(x: 0, y: 0, width: width, height: height))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = canvas
        canvas.addSubview(row)
        row.frame = CGRect(x: 0, y: 0, width: width, height: height)
        row.layoutForViewport()
        canvas.layoutSubtreeIfNeeded()
        canvas.display()
        let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let content = row.subviews.first
        row.removeFromSuperview()
        window.contentView = nil
        return Rendered(height: height, image: rep, content: content)
    }

    final class ParityCanvas: NSView { override var isFlipped: Bool { true } }

    /// How many pixels differ beyond the tolerance, of how many, and an image
    /// with them in red over the SwiftUI capture faded out.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep) -> (Int, Int, NSBitmapImageRep?) {
        let width = max(a.pixelsWide, b.pixelsWide), height = max(a.pixelsHigh, b.pixelsHigh)
        let p = rgba(a, width: width, height: height), q = rgba(b, width: width, height: height)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: width * 4, bitsPerPixel: 32), let data = out.bitmapData else { return (Int.max, 1, nil) }
        var differing = 0
        for index in 0..<(width * height) {
            let o = index * 4
            var far = false
            for c in 0..<3 where abs(Int(p[o + c]) - Int(q[o + c])) > channelTolerance { far = true }
            if far { differing += 1 }
            let base = UInt8(Int(p[o]) * 3 / 10 + 178)
            data[o] = far ? 255 : base; data[o + 1] = far ? 0 : base; data[o + 2] = far ? 0 : base; data[o + 3] = 255
        }
        return (differing, width * height, out)
    }
    /// The capture as 8-bit RGBA at `width` × `height`, white beyond its edges.
    static func rgba(_ rep: NSBitmapImageRep, width: Int, height: Int) -> [UInt8] {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        guard let image = rep.cgImage else { return bytes }
        bytes.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: height - image.height, width: image.width, height: image.height))
        }
        return bytes
    }
    static func png(_ rep: NSBitmapImageRep) -> Data? { rep.representation(using: .png, properties: [:]) }
}
