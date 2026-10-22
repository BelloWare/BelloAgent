import AppKit
import XCTest
@testable import FileView

final class FileCopyTests: ViewsTestCase {
    @MainActor private func viewer() -> (FileTextView, HeldSource, MemoryPasteboard) {
        let view = FileTextView(frame: .zero), source = HeldSource()
        view.show(source, name: "fixture.txt")
        view.selectAll(nil)
        return (view, source, MemoryPasteboard())
    }
    @MainActor func testADelayedCopyLeavesANewerPasteboardWriteAlone() {
        let (view, source, pasteboard) = viewer()
        view.copy(to: pasteboard)
        XCTAssertEqual(source.held.count, 1)
        pasteboard.clearContents(); pasteboard.setString("newer copy elsewhere", forType: .string)
        let change = pasteboard.changeCount
        source.held.removeFirst()()
        XCTAssertEqual(pasteboard.string(forType: .string), "newer copy elsewhere")
        XCTAssertEqual(pasteboard.changeCount, change)
    }
    @MainActor func testADelayedCopyWritesWhenThePasteboardIsUnchanged() {
        let (view, source, pasteboard) = viewer()
        view.copy(to: pasteboard); source.held.removeFirst()()
        XCTAssertEqual(pasteboard.string(forType: .string), "alpha beta")
    }
    @MainActor func testAClearOrNonTextWriteAlsoSupersedesADelayedCopy() {
        for data in [nil, Data([1, 2, 3])] as [Data?] {
            let (view, source, pasteboard) = viewer()
            view.copy(to: pasteboard)
            pasteboard.clearContents()
            if let data { pasteboard.setData(data, forType: .png) }
            let change = pasteboard.changeCount
            source.held.removeFirst()()
            XCTAssertNil(pasteboard.string(forType: .string))
            XCTAssertEqual(pasteboard.changeCount, change)
            XCTAssertEqual(pasteboard.data(forType: .png), data)
        }
    }
    @MainActor func testALaterCopyStillSupersedesAnEarlierRequest() {
        let (view, source, pasteboard) = viewer()
        view.copy(to: pasteboard)
        view.select(from: .start, to: FileTextPosition(line: 0, column: 5)); view.copy(to: pasteboard)
        source.held.removeFirst()()
        XCTAssertNil(pasteboard.string(forType: .string))
        source.held.removeFirst()()
        XCTAssertEqual(pasteboard.string(forType: .string), "alpha")
    }
    @MainActor func testALaterCopyFromAnotherViewerWinsInEitherCompletionOrder() {
        for olderFirst in [true, false] {
            let (first, firstSource, pasteboard) = viewer(), (second, secondSource, _) = viewer()
            second.select(from: .start, to: FileTextPosition(line: 0, column: 5))
            first.copy(to: pasteboard); second.copy(to: pasteboard)
            let change = pasteboard.changeCount
            if olderFirst {
                firstSource.held.removeFirst()()
                XCTAssertNil(pasteboard.string(forType: .string), "the superseded request must not claim the clipboard")
                XCTAssertEqual(pasteboard.changeCount, change)
            }
            secondSource.held.removeFirst()()
            let copied = pasteboard.changeCount
            if !olderFirst { firstSource.held.removeFirst()() }
            XCTAssertEqual(pasteboard.string(forType: .string), "alpha")
            XCTAssertEqual(pasteboard.changeCount, copied)
        }
    }
    @MainActor func testAnUnrelatedCopySupersedesPendingCopiesFromBothViewers() {
        for olderFirst in [true, false] {
            let (first, firstSource, pasteboard) = viewer(), (second, secondSource, _) = viewer()
            first.copy(to: pasteboard); second.copy(to: pasteboard)
            pasteboard.clearContents(); pasteboard.setString("elsewhere", forType: .string)
            let change = pasteboard.changeCount
            for source in olderFirst ? [firstSource, secondSource] : [secondSource, firstSource] { source.held.removeFirst()() }
            XCTAssertEqual(pasteboard.string(forType: .string), "elsewhere")
            XCTAssertEqual(pasteboard.changeCount, change)
        }
    }
    @MainActor private final class HeldSource: FileTextSource {
        let lines = FileTextLines("alpha beta")
        var held: [() -> Void] = []
        var lineCount: Int { lines.lineCount }
        var utf16Length: Int { lines.utf16Length }
        var longestLine: Int { lines.longestLine }
        var generation: Int { lines.generation }
        var arrival: ((ClosedRange<Int>) -> Void)?
        func utf16Length(ofLine index: Int) -> Int { lines.utf16Length(ofLine: index) }
        func text(ofLine index: Int, range: Range<Int>) -> String? { lines.text(ofLine: index, range: range) }
        func utf16Start(ofLine index: Int) -> Int { lines.utf16Start(ofLine: index) }
        func line(atUTF16 offset: Int) -> Int { lines.line(atUTF16: offset) }
        func fetch(from start: FileTextPosition, to end: FileTextPosition, completion: @escaping @MainActor (String?) -> Void) {
            let text = lines.textAtHand(from: start, to: end)
            held.append { completion(text) }
        }
    }
    @MainActor private final class MemoryPasteboard: FileCopyPasteboard {
        private var revision = 0
        private var values: [NSPasteboard.PasteboardType: Data] = [:]
        var changeCount: Int { revision }
        @discardableResult func clearContents() -> Int { revision += 1; values = [:]; return revision }
        @discardableResult func setData(_ data: Data?, forType type: NSPasteboard.PasteboardType) -> Bool { revision += 1; values[type] = data; return true }
        func data(forType type: NSPasteboard.PasteboardType) -> Data? { values[type] }
        @discardableResult func setString(_ string: String, forType type: NSPasteboard.PasteboardType) -> Bool { setData(Data(string.utf8), forType: type) }
        func string(forType type: NSPasteboard.PasteboardType) -> String? { values[type].flatMap { String(data: $0, encoding: .utf8) } }
    }
}
