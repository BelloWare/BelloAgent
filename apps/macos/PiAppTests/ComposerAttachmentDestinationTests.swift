import AppKit
import SwiftUI
import XCTest
@testable import PiApp

final class ComposerAttachmentDestinationTests: XCTestCase {
    @MainActor func testImageConversionCompletesInTheOriginatingSessionAfterRebinding() async throws {
        let board = NSPasteboard(name: .init("attachment-destination-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        board.setData(Data([1, 2, 3]), forType: .png)
        let editor = ComposerTextView()
        var origin: [URL] = [], other: [URL] = []
        let original = NativeComposer(text: .constant(""), send: { _ in }, sessionID: "first", attachFiles: { origin += $0 })
        let coordinator = NativeComposer.Coordinator(original)
        editor.attachFiles = { coordinator.parent.attachFiles($0) }
        editor.attachmentDestination = {
            .init(attach: coordinator.parent.attachFiles, reject: coordinator.parent.inputRejected)
        }
        XCTAssertTrue(editor.pasteAttachments(from: board))
        coordinator.parent = NativeComposer(text: .constant(""), send: { _ in }, sessionID: "second", attachFiles: { other += $0 })
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while origin.isEmpty && other.isEmpty && ProcessInfo.processInfo.systemUptime < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        defer { for url in origin + other { try? FileManager.default.removeItem(at: url) } }
        XCTAssertEqual(origin.count, 1)
        XCTAssertTrue(other.isEmpty, "A rebound coordinator must not redirect the completed screenshot")
    }

    private final class PromisedScreenshot: NSObject, NSPasteboardItemDataProvider {
        private let lock = NSLock()
        private var count = 0
        var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
        func pasteboard(_ pasteboard: NSPasteboard?, item: NSPasteboardItem, provideDataForType type: NSPasteboard.PasteboardType) {
            lock.lock(); count += 1; lock.unlock()
            item.setData(Data([1, 2, 3]), forType: type)
        }
    }
    @MainActor func testDragAdmissionDoesNotRequestPromisedImageBytes() {
        let board = NSPasteboard(name: .init("attachment-admission-" + UUID().uuidString))
        defer { board.releaseGlobally() }
        let item = NSPasteboardItem(), provider = PromisedScreenshot()
        item.setDataProvider(provider, forTypes: [.png, .tiff])
        board.writeObjects([item])
        for _ in 0..<100 { XCTAssertTrue(ComposerTextView.acceptsImageTypes(on: board)) }
        XCTAssertEqual(provider.requests, 0)
        XCTAssertNotNil(ComposerTextView.pastedImage(on: board))
        XCTAssertGreaterThan(provider.requests, 0, "The promise is fulfilled only on the actual drop/paste")
    }
}
