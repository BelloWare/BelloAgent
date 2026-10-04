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
    /// tolerance. None now.
    static let knownDeviations = Set<String>()

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
                                ("reply-length", { var m = reply("a4", "Cut short by the limit"); m.stopReason = "length"; return m }()),
                                ("reply-aborted", { var m = reply("a5", "Stopped while it was still writing this"); m.state = "aborted"; return m }()),
                                ("reply-error", { var m = reply("a6", "The provider failed partway"); m.stopReason = "error"; return m }()),
                                ("reply-truncated", { var m = reply("a7", "An old fragment"); m.truncated = true; return m }())] {
            var question = TranscriptMessage(id: "q-" + message.id, role: "user", text: "Question")
            question.at = message.at
            let items = TaskTranscriptPlan.items([question, message], lifecycle: nil, display: .normal)
            for item in items where TranscriptNativeReplyRow.reply(of: item) != nil { fixtures.append(Fixture(name: name, item: item)) }
        }
        return fixtures
    }

    static var failureFixtures: [Fixture] {
        func failure(_ id: String, _ text: String, detail: String? = nil) -> TranscriptItem {
            var message = TranscriptMessage(id: id, role: "system", text: text)
            message.kind = "failure"; message.detail = detail
            return .message(message)
        }
        return [
            Fixture(name: "failure-run", item: failure("failure:run:1", "The gateway closed the connection before the reply finished.",
                                                       detail: "HTTP 502 from the provider after 31 s. The request can be sent again.")),
            Fixture(name: "failure-send", item: failure("failure:send:2", "The message was refused: it is larger than the model accepts.")),
        ]
    }

    static var costLimitFixtures: [Fixture] {
        func notice(_ id: String, code: String, _ text: String, detail: String? = nil) -> TranscriptItem {
            var message = TranscriptMessage(id: id, role: "system", text: text)
            message.kind = "failure"; message.failureCode = code; message.detail = detail
            return .message(message)
        }
        return [
            Fixture(name: "cost-run", item: notice("failure:run:1", code: SessionDisplay.costLimitCode,
                                                   "This chat reached its $0.003 cost limit ($0.004 spent).", detail: "Queued messages wait until it is raised.")),
            Fixture(name: "cost-send", item: notice("failure:send:2", code: SessionDisplay.costLimitCode,
                                                    "This chat reached its $0.003 cost limit ($0.004 spent). Raise the limit to continue.")),
            Fixture(name: "cost-raised-run", item: notice("failure:run:3", code: SessionDisplay.costLimitRaised, "The limit is $10 now.")),
            Fixture(name: "cost-raised-send", item: notice("failure:send:4", code: SessionDisplay.costLimitRaised, "The limit is $10 now.")),
        ]
    }

    @MainActor func testCostLimitRowsMatchTheirSwiftUIRows() throws {
        try compare(Self.costLimitFixtures, expectNative: TranscriptNativeFailureRow.self, widths: [792, 520, 380, 300, 240])
    }

    @MainActor func testFailureRowsMatchTheirSwiftUIRows() throws {
        // Narrow too: the header's words wrap beside the Retry pill.
        try compare(Self.failureFixtures, expectNative: TranscriptNativeFailureRow.self, widths: [792, 520, 380, 300, 240])
    }

    static var noticeFixtures: [Fixture] {
        func row(_ id: String, kind: String, _ text: String, detail: String? = nil) -> TranscriptItem {
            var message = TranscriptMessage(id: id, role: "system", text: text)
            message.kind = kind; message.detail = detail
            return .message(message)
        }
        return [
            Fixture(name: "notice", item: row("n1", kind: "notice", "Retrying in 4 s (attempt 2 of 5)")),
            Fixture(name: "branch", item: row("b1", kind: "branch", "")),
            Fixture(name: "branch-detail", item: row("b2", kind: "branch", "", detail: "You changed the question")),
            Fixture(name: "branch-lines", item: row("b4", kind: "branch", "", detail: "first\nsecond\n")),
            Fixture(name: "branch-long", item: row("b3", kind: "branch", String(repeating: "The edit replaced the earlier question with a longer one. ", count: 4))),
        ]
    }

    static var statusFixtures: [Fixture] {
        func status(_ id: String, _ text: String, state: String? = nil, truncated: Bool = false) -> TranscriptItem {
            var message = TranscriptMessage(id: id, role: "system", text: text)
            message.state = state; message.truncated = truncated ? true : nil
            return .message(message)
        }
        return [
            Fixture(name: "status-short", item: status("s1", "Model changed to gpt-6.1-sol")),
            Fixture(name: "status-long", item: status("s2", String(repeating: "The helper restarted after an update and reloaded this chat's settings. ", count: 3))),
            Fixture(name: "status-failed", item: status("s3", "The request stopped", state: "error")),
            Fixture(name: "status-truncated", item: status("s4", "Saved status", truncated: true)),
        ]
    }

    @MainActor func testVersionBannersMatchTheirSwiftUIRows() throws {
        func banner(_ id: String, detail: String) -> TranscriptItem {
            var message = TranscriptMessage(id: id, role: "system", text: "Version 1 of 2")
            message.kind = "versionBanner"; message.detail = detail
            return .message(message)
        }
        try compare([Fixture(name: "banner", item: banner("version-banner:1", detail: "Replies from before your edit")),
                     Fixture(name: "banner-long", item: banner("version-banner:2", detail: String(repeating: "Replies from before your edit, read only. ", count: 4)))],
                    expectNative: TranscriptNativeVersionBannerRow.self, widths: [792, 520, 380, 240])
    }

    @MainActor func testStatusRowsMatchTheirSwiftUIRows() throws {
        try compare(Self.statusFixtures, expectNative: TranscriptNativeStatusRow.self)
    }

    @MainActor func testNoticeRowsMatchTheirSwiftUIRows() throws {
        try compare(Array(Self.noticeFixtures.prefix(1)), expectNative: TranscriptNativeNoticeRow.self)
        try compare(Array(Self.noticeFixtures.dropFirst()), expectNative: TranscriptNativeBranchRow.self)
    }

    @MainActor func testReplyBodiesMatchTheirSwiftUIRows() throws {
        let fixtures = Self.replyFixtures
        // A reply still waiting for its first token is not a body row yet.
        XCTAssertEqual(Set(fixtures.map(\.name)), ["reply-prose", "reply-markdown", "reply-length", "reply-aborted", "reply-error", "reply-truncated"],
                       "every finished reply must plan a body row")
        try compare(fixtures, expectNative: TranscriptNativeReplyRow.self)
    }

    // MARK: Drawing a row both ways

    @MainActor private func compare<T: NSView>(_ fixtures: [Fixture], expectNative: T.Type, widths: [CGFloat] = [792, 520, 380]) throws {
        let out = testEnvironment("PI_PARITY_OUT").map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let out { try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true) }
        var failures: [String] = []
        for fixture in fixtures {
            for width in widths {
                for dark in [false, true] {
                    let label = "\(fixture.name)-\(Int(width))-\(dark ? "dark" : "light")"
                    let hosted = render(fixture.item, width: width, dark: dark, native: false)
                    let native = render(fixture.item, width: width, dark: dark, native: true)
                    XCTAssertTrue(native.content is T, "\(label): the native renderer did not draw this row")
                    XCTAssertFalse(hosted.content is T, "\(label): the SwiftUI renderer drew a native row")
                    if hosted.height != native.height {
                        failures.append("\(label): height \(native.height) native, \(hosted.height) SwiftUI")
                    }
                    let (differing, total, diff) = Self.difference(hosted.image, native.image, masked: native.animated)
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

    /// `animated`: where the native row draws something that moves with the
    /// clock (a turning ring), in pixels; both captures skip it.
    struct Rendered { let height: CGFloat; let image: NSBitmapImageRep; let content: NSView?; var animated: [CGRect] = [] }

    @MainActor private func render(_ item: TranscriptItem, width: CGFloat, dark: Bool, native: Bool) -> Rendered {
        let previous = TranscriptRowRenderer.native
        TranscriptRowRenderer.native = native
        defer { TranscriptRowRenderer.native = previous }
        var environment = TranscriptRowEnvironment()
        environment.colorScheme = dark ? .dark : .light
        let row = TranscriptRowContainer(item: item, fresh: false, actions: TranscriptActions(), environment: environment)
        // Measured in the window, as the document measures a row it has
        // mounted: SwiftUI rounds sizes to the pixels of the window it is in.
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: 100), styleMask: [.borderless], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let canvas = ParityCanvas(frame: CGRect(x: 0, y: 0, width: width, height: 100))
        canvas.wantsLayer = true
        canvas.layer?.backgroundColor = NSColor.white.cgColor
        window.contentView = canvas
        canvas.addSubview(row)
        let height = row.measure(width: width).height
        window.setContentSize(CGSize(width: width, height: height))
        canvas.frame = CGRect(x: 0, y: 0, width: width, height: height)
        row.frame = CGRect(x: 0, y: 0, width: width, height: height)
        row.layoutForViewport()
        canvas.layoutSubtreeIfNeeded()
        canvas.display()
        let rep = canvas.bitmapImageRepForCachingDisplay(in: canvas.bounds)!
        canvas.cacheDisplay(in: canvas.bounds, to: rep)
        let content = row.subviews.first
        if testEnvironment("PI_PARITY_FRAMES") == "1", let content {
            func walk(_ view: NSView, _ depth: Int) {
                FileHandle.standardError.write(Data("FRAME \(String(repeating: " ", count: depth))\(type(of: view)) \(view.frame)\n".utf8))
                for child in view.subviews { walk(child, depth + 1) }
            }
            walk(content, 0)
        }
        if testEnvironment("PI_PARITY_AX") == "1", let content {
            // SwiftUI's own geometry, from its accessibility frames, row-relative.
            func walk(_ element: Any, _ depth: Int) {
                guard depth < 12, let object = element as? NSAccessibilityProtocol else { return }
                let frame = object.accessibilityFrame()
                let inWindow = window.convertFromScreen(frame)
                let local = CGRect(x: inWindow.minX, y: height - inWindow.maxY, width: inWindow.width, height: inWindow.height)
                let role = object.accessibilityRole()?.rawValue ?? "?"
                let label = object.accessibilityLabel() ?? (object.accessibilityValue() as? String) ?? ""
                FileHandle.standardError.write(Data("AX \(native ? "N" : "S") \(String(repeating: " ", count: depth))\(role) [\(label.prefix(30))] \(local)\n".utf8))
                for child in object.accessibilityChildren() ?? [] { walk(child, depth + 1) }
            }
            walk(content, 0)
        }
        var animated: [CGRect] = []
        func findAnimated(_ view: NSView) {
            if view is TranscriptSpinner, !view.isHidden {
                let rect = view.convert(view.bounds, to: canvas).insetBy(dx: -1, dy: -1)
                let scale = CGFloat(rep.pixelsWide) / width
                animated.append(CGRect(x: rect.minX * scale, y: rect.minY * scale, width: rect.width * scale, height: rect.height * scale))
            }
            for child in view.subviews { findAnimated(child) }
        }
        findAnimated(row)
        row.removeFromSuperview()
        window.contentView = nil
        return Rendered(height: height, image: rep, content: content, animated: animated)
    }

    final class ParityCanvas: NSView { override var isFlipped: Bool { true } }

    /// How many pixels differ beyond the tolerance, of how many, and an image
    /// with them in red over the SwiftUI capture faded out.
    static func difference(_ a: NSBitmapImageRep, _ b: NSBitmapImageRep, masked: [CGRect] = []) -> (Int, Int, NSBitmapImageRep?) {
        let width = max(a.pixelsWide, b.pixelsWide), height = max(a.pixelsHigh, b.pixelsHigh)
        let p = rgba(a, width: width, height: height), q = rgba(b, width: width, height: height)
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: width * 4, bitsPerPixel: 32), let data = out.bitmapData else { return (Int.max, 1, nil) }
        var differing = 0
        for index in 0..<(width * height) {
            let o = index * 4
            var far = false
            let point = CGPoint(x: CGFloat(index % width) + 0.5, y: CGFloat(index / width) + 0.5)
            let skipped = masked.contains { $0.contains(point) }
            for c in 0..<3 where !skipped && abs(Int(p[o + c]) - Int(q[o + c])) > channelTolerance { far = true }
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
