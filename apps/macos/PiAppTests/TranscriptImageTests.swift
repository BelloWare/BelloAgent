import XCTest
import AppKit
import ImageIO
@testable import PiApp

/// Generated image messages, with no clipboard, provider or owner files.
final class TranscriptImageTests: XCTestCase {
    static func image(_ alternate: Bool = false, width: Int = 960, height: Int = 600) throws -> Data {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                            bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(red: alternate ? 0.13 : 0.98, green: alternate ? 0.48 : 0.75, blue: alternate ? 0.58 : 0.36, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.setFillColor(CGColor(gray: 1, alpha: 0.85))
        context.fill(CGRect(x: width / 8, y: height / 4, width: width / 3, height: height / 2))
        context.setFillColor(CGColor(gray: 0.18, alpha: 1))
        context.fillEllipse(in: CGRect(x: width / 2, y: height / 3, width: width / 3, height: height / 3))
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try XCTUnwrap(context.makeImage()), nil)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        return data as Data
    }

    static func message(text: String = "Compare these two images.", id: String = "images", count: Int = 2) throws -> TranscriptMessage {
        .project(id: id, message: try body(text: text, count: count))
    }
    static func body(text: String, count: Int) throws -> [String: WireValue] {
        let images = try (0..<count).map { index in
            WireValue.object(["type": .string("image"), "mimeType": .string("image/png"), "data": .string(try image(index % 2 == 1).base64EncodedString())])
        }
        return ["role": .string("user"), "content": .array((text.isEmpty ? [] : [.object(["type": .string("text"), "text": .string(text)])]) + images)]
    }

    func testJournalAndLiveRowsKeepImageCountsWithoutImageBytes() throws {
        let journal = try Self.message()
        let live = try XCTUnwrap(TranscriptMessage.page(.array([.object(["id": .string("images"), "role": .string("user"), "text": .string(journal.text), "imageCount": .number(2)])])).first)
        for row in [journal, live] {
            let encoded = try JSONEncoder().encode(row)
            let fields = try XCTUnwrap(JSONDecoder().decode(WireValue.self, from: encoded).object)
            XCTAssertEqual(fields["imageCount"]?.number, 2, "A text caption must not hide its attachments")
            XCTAssertLessThan(encoded.count, 2_048, "The window keeps counts/references, never base64 image data")
            XCTAssertEqual(row.text, "Compare these two images.")
        }
    }
}

final class TranscriptImageRowTests: XCTestCase {
    @MainActor static func views<T: NSView>(_ type: T.Type, in root: NSView) -> [T] {
        ((root as? T).map { [$0] } ?? []) + root.subviews.flatMap { views(type, in: $0) }
    }
    @MainActor func testTextAndImageOnlyRowsShowNamedThumbnailButtons() throws {
        for caption in ["Compare these two images.", "", "2 images"] {
            let message = try TranscriptImageTests.message(text: caption)
            let row = TranscriptRowContainer(item: .message(message), fresh: false, actions: TranscriptActions())
            let height = row.measure(width: 500).height
            row.frame = CGRect(x: 0, y: 0, width: 500, height: height); row.layoutForViewport()
            let buttons = Self.views(PiKit.ButtonBase.self, in: row).filter { $0.accessibilityLabel()?.hasPrefix("Image ") == true }
            XCTAssertEqual(buttons.map { $0.accessibilityLabel() ?? "" }, ["Image 1 of 2", "Image 2 of 2"])
            for button in buttons { XCTAssertGreaterThan(button.frame.height, 40); XCTAssertGreaterThan(button.frame.width, 40) }
            let text = Self.views(TranscriptPlainTextView.self, in: row).filter { !$0.isHidden }
            XCTAssertEqual(text.map(\.string), caption.isEmpty ? [] : [caption], "An image-only message draws the thumbnails in place of its label")
            if let text = text.first, let button = buttons.first {
                XCTAssertGreaterThanOrEqual(row.convert(button.bounds, from: button).minY, row.convert(text.bounds, from: text).maxY + 5)
            }
        }
    }

    @MainActor func testImagesFollowWritingDirectionAndDisabledState() throws {
        let message = try TranscriptImageTests.message(), item = TranscriptItem.message(message)
        let row = TranscriptRowContainer(item: item, fresh: false, actions: TranscriptActions())
        let height = row.measure(width: 500).height
        row.frame = CGRect(x: 0, y: 0, width: 500, height: height); row.layoutForViewport()
        let before = Self.views(TranscriptImageButton.self, in: row)
        XCTAssertLessThan(try XCTUnwrap(before.first).frame.minX, try XCTUnwrap(before.last).frame.minX)
        var environment = TranscriptRowEnvironment(); environment.layoutDirection = .rightToLeft; environment.isEnabled = false
        row.update(item: item, fresh: false, actions: TranscriptActions(), environment: environment); row.layoutForViewport()
        let after = Self.views(TranscriptImageButton.self, in: row)
        XCTAssertGreaterThan(try XCTUnwrap(after.first).frame.minX, try XCTUnwrap(after.last).frame.minX)
        XCTAssertTrue(after.allSatisfy { !$0.isEnabled })
    }
}
