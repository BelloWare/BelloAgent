import AppKit
import Darwin
import XCTest
@testable import PiApp

final class FilePreviewRefreshTests: XCTestCase {
    @MainActor func testSiblingNotificationsLetTheActivePreviewPublish() async throws {
        let folder = scratchRoot("preview-refresh")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("image.bmp")
        try Self.bitmap(red: true).write(to: url)
        let tab = FileTab(url: url, projectID: nil), gate = PreviewDecodeGate()
        defer { tab.willClose() }
        addTeardownBlock { await gate.releaseAll() }
        tab.didShow()
        let preview = tab.preview
        preview.beforeDecode = { await gate.wait() }
        preview.load()
        let first = try XCTUnwrap(preview.readingTask)
        try await eventually("first preview read entered", until: { await gate.count > 0 })
        for _ in 0..<12 { tab.followChange(); try await Task.sleep(for: .milliseconds(10)) }
        await gate.releaseFirst()
        await first.value
        try await eventually("queued metadata recheck entered", until: { await gate.count >= 2 })
        let checks = await gate.count
        XCTAssertEqual(checks, 2, "the notification burst queues just one check after the active read")
        // Keep delivering the watcher's callback while later metadata reads
        // are held: the first completed decode must already be on screen.
        for _ in 0..<12 { tab.followChange(); try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(preview.image, "unchanged image must appear during ongoing folder activity")
        XCTAssertFalse(preview.loading)
        XCTAssertEqual(preview.decodeStarts, 1, "notifications must not cancel or repeat the active decode")
        preview.beforeDecode = nil
        await gate.releaseAll()
        try await eventually("metadata recheck drained") { preview.readingTask == nil }
        XCTAssertEqual(preview.decodeStarts, 1)
    }

    @MainActor func testSuccessfulPreviewFollowsSameSizeAndMtimeOverwrite() async throws {
        let folder = scratchRoot("preview-overwrite")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("image.bmp"), red = Self.bitmap(red: true), blue = Self.bitmap(red: false)
        XCTAssertEqual(red.count, blue.count)
        try red.write(to: url)
        let preview = FilePreview(url: url)
        defer { preview.close() }
        preview.load(); await preview.readingTask?.value
        let first = try XCTUnwrap(preview.image?.representations.first as? NSBitmapImageRep)
        XCTAssertGreaterThan(try XCTUnwrap(first.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)).redComponent, 0.9)
        var before = stat(); XCTAssertEqual(stat(url.path, &before), 0)
        try await Task.sleep(for: .milliseconds(10))
        try blue.write(to: url)
        var times = [before.st_atimespec, before.st_mtimespec]
        XCTAssertEqual(utimensat(AT_FDCWD, url.path, &times, 0), 0)
        var after = stat(); XCTAssertEqual(stat(url.path, &after), 0)
        XCTAssertEqual(before.st_ino, after.st_ino); XCTAssertEqual(before.st_size, after.st_size)
        XCTAssertEqual(before.st_mtimespec.tv_sec, after.st_mtimespec.tv_sec)
        XCTAssertEqual(before.st_mtimespec.tv_nsec, after.st_mtimespec.tv_nsec)
        XCTAssertTrue(before.st_ctimespec.tv_sec != after.st_ctimespec.tv_sec || before.st_ctimespec.tv_nsec != after.st_ctimespec.tv_nsec)
        preview.load(); await preview.readingTask?.value
        let updated = try XCTUnwrap(preview.image?.representations.first as? NSBitmapImageRep)
        XCTAssertGreaterThan(try XCTUnwrap(updated.colorAt(x: 0, y: 0)?.usingColorSpace(.deviceRGB)).blueComponent, 0.9, "same timestamp must not keep old pixels")
        XCTAssertEqual(preview.decodeStarts, 2)
    }

    // A 2x2, 24-bit BMP: uncompressed, equal length for either colour.
    static func bitmap(red: Bool) -> Data {
        var data = Data([0x42, 0x4d, 70, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0,
                         40, 0, 0, 0, 2, 0, 0, 0, 2, 0, 0, 0, 1, 0, 24, 0])
        data.append(Data(repeating: 0, count: 24))
        for _ in 0..<2 { data.append(contentsOf: red ? [0, 0, 255, 0, 0, 255, 0, 0] : [255, 0, 0, 255, 0, 0, 0, 0]) }
        return data
    }
}

private actor PreviewDecodeGate {
    private(set) var count = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var released = false
    func wait() async {
        count += 1
        if !released { await withCheckedContinuation { waiters.append($0) } }
    }
    func releaseFirst() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
    func releaseAll() { released = true; let pending = waiters; waiters = []; pending.forEach { $0.resume() } }
}
