import XCTest
import SwiftUI
import AppKit
@testable import PiApp

final class CapturedBodyTests: XCTestCase {
    @MainActor func testLargeStreamIndexesWithoutJSONAndFullCopyUsesBoundedCache() async throws {
        let source = (0..<20_000).map { "event: response.output_text.delta\ndata: {\"delta\":\"value \($0)\",\"nested\":{\"tokens\":\($0)}}\n\n" }.joined()
        let bytes = Data(source.utf8), descriptor = metadata(bytes)
        let document = try await CapturedBodyWorker.shared.run { try CapturedBodyDocument.parse(bytes: bytes, metadata: descriptor, combine: false) }
        let stream = try XCTUnwrap(document.eventStream)
        XCTAssertEqual(stream.frames.count, 20_000)
        XCTAssertEqual(stream.storage.parsedFrames, 0, "Indexing must not parse or pretty-print invisible JSON")
        XCTAssertEqual(stream.storage.cachedBytes, 0)
        XCTAssertNil(stream.outline.eagerFormatted)
        let copy = CapturedBodyCopySource(id: document.id, document: document, format: .json, hex: "", plain: "")
        let rendered = try await copy.render()
        XCTAssertTrue(rendered.contains("Event 20000")); XCTAssertTrue(rendered.contains("value 19999"))
        XCTAssertLessThanOrEqual(stream.storage.cachedBytes, stream.storage.cacheLimit)
        XCTAssertEqual(document.bytes, bytes)
    }

    @MainActor func testLazyNativeEventRowLoadsAndExpandsWithoutFormattingAllFrames() async throws {
        let bytes = Data(String(repeating: "event: response.output_text.delta\ndata: {\"delta\":\"visible text\",\"nested\":{\"a\":1}}\n\n", count: 5_000).utf8)
        let stream = try XCTUnwrap(CapturedEventStream.parse(bytes))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 650, height: 350), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        var selection = ""
        let hosted = NSHostingView(rootView: JSONOutlineView(json: stream.outline, selection: Binding(get: { selection }, set: { selection = $0 }), expandRevision: 0, expandAll: false))
        window.contentView = hosted; window.makeKeyAndOrderFront(nil)
        defer { window.contentView = nil; window.close() }
        let outline = try await renderedOutline(in: hosted, window: window)
        let root = try XCTUnwrap(outline.item(atRow: 0) as? JSONOutlineNode), frame = root.child(0)
        for _ in 0..<100 where frame.prepared == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(frame.prepared)
        XCTAssertEqual(frame.summary, "JSON data")
        XCTAssertLessThan(stream.storage.parsedFrames, 100, "Only visible frame rows should parse")
        outline.expandItem(frame)
        XCTAssertEqual(frame.child(0).child(0).detail, "visible text")
        XCTAssertGreaterThan(outline.numberOfRows, 5_001)
    }

    @MainActor private func metadata(_ bytes: Data, state: String = "complete", observed: Int? = nil, hash: String = "unchanged") -> CapturedBodyMetadata {
        CapturedBodyMetadata(body: ["state": .string(state), "retainedBytes": .number(Double(bytes.count)),
                                    "observedBytes": .number(Double(observed ?? bytes.count))], hash: .string(hash))
    }
    @MainActor private func source(_ bytes: Data, state: String = "complete", observed: Int? = nil) -> CapturedBodySource {
        let description = metadata(bytes, state: state, observed: observed)
        return CapturedBodySource(metadata: { description }, page: { offset in
            (bytes.subdata(in: offset..<min(offset + 32_768, bytes.count)), bytes.count)
        })
    }

    @MainActor private func renderedOutline(in hosted: NSView, window: NSWindow) async throws -> NSOutlineView {
        func find(_ view: NSView) -> NSOutlineView? {
            if let outline = view as? NSOutlineView { return outline }
            if let scroll = view as? NSScrollView, let outline = scroll.documentView as? NSOutlineView { return outline }
            return view.subviews.compactMap { find($0) }.first
        }
        // The reader publishes copy text before SwiftUI mounts its native
        // outline. Wait for the actual attached, populated view and layout,
        // rather than using the independent text binding as UI readiness.
        for _ in 0..<200 {
            hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
            if let outline = find(hosted), outline.window === window,
               outline.numberOfRows > 1, outline.bounds.width > 0, outline.bounds.height > 0 { return outline }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("The captured-body outline did not render in its window")
        return try XCTUnwrap(find(hosted))
    }

    @MainActor func testLoadsAllJSONBytesAndPreservesUnicodeAcrossPageBoundary() async throws {
        // The first emoji begins two bytes before the archive page boundary.
        let prefix = #"{"message":""# + String(repeating: "x", count: 32_754)
        let bytes = Data((prefix + String(repeating: "🌍", count: 20_000) + #"","nested":{"model":"auto-router","enabled":true},"items":[1,null,"done"]}"#).utf8)
        XCTAssertEqual(Array(bytes[32_766..<32_770]), [0xf0, 0x9f, 0x8c, 0x8d])
        var offsets: [Int] = [], progress: [(Int, Int)] = []
        let descriptor = metadata(bytes)
        let value = try await CapturedBodyReader.read(kind: "request", source: CapturedBodySource(metadata: { descriptor }, page: { offset in
            offsets.append(offset)
            return (bytes.subdata(in: offset..<min(offset + 32_768, bytes.count)), bytes.count)
        }), progress: { progress.append(($0, $1)) })
        XCTAssertEqual(value.bytes, bytes)
        XCTAssertGreaterThan(offsets.count, 3)
        XCTAssertEqual(offsets, Array(stride(from: 0, to: bytes.count, by: 32_768)))
        XCTAssertEqual(progress.last?.0, bytes.count)
        XCTAssertEqual(progress.last?.1, bytes.count)
        let json = try XCTUnwrap(value.json)
        let parsed = try XCTUnwrap(json.value as? [String: Any])
        XCTAssertEqual(parsed["message"] as? String, String(repeating: "x", count: 32_754) + String(repeating: "🌍", count: 20_000))
        XCTAssertTrue(json.formatted.contains("\n"))
        XCTAssertFalse(json.formatted.contains("�"))
        XCTAssertEqual(CapturedBodyFormat.allCases.first, .json)
    }

    @MainActor func testFullSSEFormatsEveryFrameWhilePartialBytesRemainUnchanged() async throws {
        let text = String(repeating: "event: response.output_text.delta\ndata: {\"delta\":\"Hello 🌍\"}\n\n", count: 1_500) + "data: [DONE]\n\n"
        let bytes = Data(text.utf8)
        let value = try await CapturedBodyReader.read(kind: "response", source: source(bytes, state: "partial", observed: bytes.count + 900))
        XCTAssertEqual(value.bytes, bytes)
        XCTAssertEqual(String(decoding: value.bytes, as: UTF8.self), text)
        XCTAssertNil(value.json, "The full SSE transport body is not a JSON document")
        let stream = try XCTUnwrap(value.eventStream)
        XCTAssertEqual(stream.frames.count, 1_501, "Every retained frame is loaded, with no UI pagination")
        XCTAssertEqual((stream.frames[0].json as? [String: Any])?["delta"] as? String, "Hello 🌍")
        XCTAssertEqual(stream.frames.last?.data, "[DONE]")
        XCTAssertEqual(stream.frames.last?.summary, "Stream sentinel")
        XCTAssertNotNil(value.structured)
        XCTAssertTrue(value.metadata.summary.hasPrefix("partial · all"))
        XCTAssertTrue(value.metadata.summary.contains("\(bytes.count + 900) observed"))
        XCTAssertTrue(String(decoding: value.bytes, as: UTF8.self).hasSuffix("data: [DONE]\n\n"))
    }

    @MainActor func testResponseCompletedAndMultilineSSEPreserveFramingAndFields() throws {
        let text = "\u{FEFF}: gateway keepalive\r\nid: first\r\nretry: 1000\r\nevent: ignored\r\nevent: response.completed\r\nx-debug: retained\r\n"
            + "data: {\"type\":\"response.completed\",\r\ndata: \"response\":{\"model\":\"auto-router\",\"router_model_name\":\"gpt-5.4-mini\",\"usage\":{\"input_tokens\":38,\"output_tokens\":302,\"output_tokens_details\":{\"reasoning_tokens\":253}}}}\r\n\r\n"
            + "data: [DONE]\r\r"
        let bytes = Data(text.utf8)
        let document = try CapturedBodyDocument.parse(bytes: bytes, metadata: metadata(bytes))
        let stream = try XCTUnwrap(document.eventStream)
        XCTAssertEqual(stream.frames.count, 2)
        let completed = stream.frames[0]
        XCTAssertEqual(completed.label, "1 · response.completed")
        XCTAssertEqual(Array(completed.fields.prefix(6)), [": gateway keepalive", "id: first", "retry: 1000", "event: ignored", "event: response.completed", "x-debug: retained"])
        XCTAssertTrue(completed.terminated)
        let response = try XCTUnwrap((completed.json as? [String: Any])?["response"] as? [String: Any])
        XCTAssertEqual(response["router_model_name"] as? String, "gpt-5.4-mini")
        let usage = try XCTUnwrap(response["usage"] as? [String: Any])
        XCTAssertEqual(usage["output_tokens"] as? Int, 302)
        XCTAssertEqual((usage["output_tokens_details"] as? [String: Any])?["reasoning_tokens"] as? Int, 253)
        XCTAssertTrue(try XCTUnwrap(completed.formattedData).contains("\n"))
        XCTAssertTrue(stream.outline.formatted.contains("Event 2 · [DONE] — Stream sentinel"))
        XCTAssertEqual(document.bytes, bytes, "Neither BOM handling nor formatted multiline data changes original transport bytes")
        XCTAssertNil(document.json, "The original SSE transport stays separate from its combined response view")
    }

    @MainActor func testCombinedViewCopiesResponseJSONAndKeepsEventsAndRawAvailable() throws {
        let text = "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_fixture\",\"status\":\"completed\",\"model\":\"auto-router\",\"router_model_name\":\"gpt-5.4-mini\",\"output\":[{\"type\":\"message\",\"content\":[{\"type\":\"output_text\",\"text\":\"Hello 🌍\"}]}],\"usage\":{\"input_tokens\":38,\"output_tokens\":302,\"total_tokens\":340}}}\n\ndata: [DONE]\n\n"
        let bytes = Data(text.utf8)
        let document = try CapturedBodyDocument.parse(bytes: bytes, metadata: metadata(bytes, state: "partial", observed: bytes.count + 20))
        XCTAssertEqual(document.availableFormats(kind: "response").map(\.0), [.combined, .json, .text, .hex])
        XCTAssertEqual(document.availableFormats(kind: "response").map(\.1), ["Combined JSON", "Events", "UTF-8", "Hex"])
        XCTAssertEqual(document.resolvedFormat(.combined, kind: "response"), .combined)
        XCTAssertEqual(document.resolvedFormat(.combined, kind: "request"), .json)
        let copied = document.displayedText(format: .combined)
        let response = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(copied.utf8)) as? [String: Any])
        XCTAssertEqual(response["id"] as? String, "resp_fixture")
        XCTAssertEqual(response["router_model_name"] as? String, "gpt-5.4-mini")
        XCTAssertNil(response["response"], "Copy exports the combined response object, without an event wrapper")
        XCTAssertEqual(document.structured(format: .combined)?.id, document.combinedResponse?.json.id)
        XCTAssertEqual(document.structured(format: .json)?.id, document.eventStream?.outline.id)
        XCTAssertNotEqual(document.structured(format: .combined)?.id, document.structured(format: .json)?.id,
                          "Changing view resets the native outline instead of retaining a stale event tree")
        XCTAssertTrue(document.displayedText(format: .json).contains("Event 2 · [DONE]"))
        // The plain UTF-8 view is decoded once by the view, off the main actor,
        // and handed in; the document never re-decodes its bytes per render.
        XCTAssertEqual(document.displayedText(format: .text, plain: String(decoding: bytes, as: UTF8.self)), text)
        XCTAssertEqual(document.displayedText(format: .text), "", "the document does not decode a 64 MiB body on its own")
        XCTAssertEqual(document.displayedText(format: .hex, hex: try CapturedBodyHex.render(bytes)), try CapturedBodyHex.render(bytes))
        XCTAssertEqual(document.bytes, bytes)
        XCTAssertTrue(document.metadata.summary.hasPrefix("partial"), "A terminal object does not remove the retained-capture warning")

        for bytes in [Data(#"{"output":[]}"#.utf8), Data("data: {\"type\":\"message_start\"}\n\n".utf8)] {
            let ordinary = try CapturedBodyDocument.parse(bytes: bytes, metadata: metadata(bytes))
            XCTAssertNil(ordinary.combinedResponse)
            XCTAssertEqual(ordinary.resolvedFormat(.combined, kind: "response"), .json)
            XCTAssertFalse(ordinary.availableFormats(kind: "response").contains { $0.0 == .combined })
        }
    }

    @MainActor func testLoadingEventsDefersCombinedResponseUntilRequestedAndClosingReleasesIt() async throws {
        let bytes = Data("event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_lazy\",\"status\":\"completed\",\"output\":[]}}\n\n".utf8)
        let controller = CapturedBodyController()
        await controller.load(kind: "response", source: source(bytes))
        let initial = try XCTUnwrap(controller.document)
        XCTAssertEqual(initial.bytes, bytes)
        XCTAssertNil(initial.combinedResponse)
        XCTAssertFalse(initial.combinationFinished)
        XCTAssertTrue(initial.availableFormats(kind: "response").contains { $0.0 == .combined })
        await controller.prepareCombined()
        let ready = try XCTUnwrap(controller.document)
        XCTAssertEqual(ready.bytes, bytes)
        XCTAssertEqual((ready.combinedResponse?.json.value as? [String: Any])?["id"] as? String, "resp_lazy")
        XCTAssertTrue(ready.combinationFinished)
        controller.cancel()
        XCTAssertNil(controller.document)
    }

    @MainActor func testSSEInvalidDataCommentsAndUnfinishedTailRemainVisible() throws {
        let text = ": keepalive\n\ndata: not JSON\n\ndata: [DONE]\n\nevent: response.completed\ndata: {\"response\":"
        let bytes = Data(text.utf8)
        let document = try CapturedBodyDocument.parse(bytes: bytes, metadata: metadata(bytes, state: "partial", observed: bytes.count + 400))
        let frames = try XCTUnwrap(document.eventStream).frames
        XCTAssertEqual(frames.count, 4)
        XCTAssertNil(frames[0].data)
        XCTAssertEqual(frames[0].fields, [": keepalive"])
        XCTAssertEqual(frames[1].data, "not JSON")
        XCTAssertNil(frames[1].json)
        XCTAssertEqual(frames[1].summary, "Non-JSON data")
        XCTAssertEqual(frames[2].data, "[DONE]")
        XCTAssertFalse(frames[3].terminated)
        XCTAssertEqual(frames[3].data, #"{"response":"#)
        XCTAssertTrue(frames[3].summary.contains("unfinished frame"))
        XCTAssertEqual(frames[3].entry(0).1 as? String, #"{"response":"#)
        XCTAssertTrue(document.metadata.summary.hasPrefix("partial · all"))
        XCTAssertEqual(document.bytes, bytes)

        for invalid in [Data("This is not JSON or an event stream.".utf8), Data([0xff, 0, 0x80])] {
            let raw = try CapturedBodyDocument.parse(bytes: invalid, metadata: metadata(invalid))
            XCTAssertNil(raw.structured)
            XCTAssertEqual(raw.bytes, invalid)
        }
    }

    @MainActor func testSSETreeExpandsJSONPayloadAndKeepsLargeFrameListLazy() throws {
        let bytes = Data(("event: response.completed\ndata: {\"response\":{\"model\":\"gpt-5.4-mini\",\"usage\":{\"total_tokens\":340}}}\n\n" + "data: [DONE]\n\n").utf8)
        let stream = try XCTUnwrap(CapturedBodyDocument.parse(bytes: bytes, metadata: metadata(bytes)).eventStream)
        let root = JSONOutlineNode(key: stream.outline.rootLabel, value: stream.outline.value, formattedDetail: stream.outline.formatted)
        XCTAssertEqual(root.cachedChildren, 0)
        let completed = root.child(0)
        XCTAssertEqual(completed.key, "1 · response.completed")
        XCTAssertEqual(completed.summary, "JSON data")
        let data = completed.child(0)
        XCTAssertEqual(data.key, "data")
        XCTAssertEqual(data.child(0).key, "response")
        XCTAssertEqual(data.child(0).child(0).detail, "gpt-5.4-mini")
        XCTAssertEqual(root.cachedChildren, 1)
        XCTAssertEqual(completed.child(1).key, "SSE fields")
        XCTAssertEqual(completed.child(1).child(0).detail, "event: response.completed")
        XCTAssertEqual(completed.detail, stream.frames[0].formatted)
        XCTAssertEqual(root.detail, stream.outline.formatted)
        XCTAssertEqual(JSONOutlineNode(key: "Server-sent events", value: stream.outline.value).detail, stream.outline.formatted,
                       "Even an uncached event root must not pass custom frame values to JSONSerialization")
        let emptyJSON = JSONOutlineNode(key: "empty", value: [Any]()).detail
        XCTAssertFalse(emptyJSON.contains("Server-sent events"))
        XCTAssertEqual((try JSONSerialization.jsonObject(with: Data(emptyJSON.utf8)) as? [Any])?.count, 0)

        var selectedDetail = ""
        let coordinator = JSONOutlineView.Coordinator(selection: Binding(get: { selectedDetail }, set: { selectedDetail = $0 }))
        coordinator.root = root
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.dataSource = coordinator; outline.delegate = coordinator
        outline.reloadData(); outline.expandItem(root)
        XCTAssertEqual(outline.numberOfRows, 3)
        // The coordinator writes the SwiftUI binding on the next run-loop turn, never inside the outline's own update.
        func settle() { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
        outline.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        coordinator.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification, object: outline))
        XCTAssertEqual(selectedDetail, "", "nothing is written synchronously from the delegate")
        settle(); XCTAssertEqual(selectedDetail, stream.outline.formatted)
        outline.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        coordinator.outlineViewSelectionDidChange(Notification(name: NSOutlineView.selectionDidChangeNotification, object: outline))
        settle(); XCTAssertEqual(selectedDetail, stream.frames[0].formatted)
        outline.expandItem(completed)
        XCTAssertEqual(outline.numberOfRows, 6)
        outline.expandItem(data); outline.expandItem(data.child(0))
        XCTAssertEqual(outline.numberOfRows, 9)
        outline.collapseItem(completed, collapseChildren: true)
        XCTAssertEqual(outline.numberOfRows, 3)
        XCTAssertTrue(outline.isItemExpanded(root))
    }

    @MainActor func testRejectsChangedManifestAndMissingLaterPage() async throws {
        let bytes = Data(repeating: 97, count: 70_000), description = metadata(Data(repeating: 97, count: 70_000))
        var descriptions = 0
        let changing = CapturedBodySource(metadata: {
            descriptions += 1
            return descriptions == 1 ? description : CapturedBodyMetadata(body: description.body, hash: .string("changed"))
        }, page: { offset in (bytes.subdata(in: offset..<min(offset + 32_768, bytes.count)), bytes.count) })
        do { _ = try await CapturedBodyReader.read(kind: "response", source: changing); XCTFail("Changing a same-length capture must fail") }
        catch { XCTAssertTrue(error.localizedDescription.contains("changed")) }
        let missing = CapturedBodySource(metadata: { description }, page: { offset in
            (offset == 0 ? bytes.prefix(32_768) : Data(), bytes.count)
        })
        do { _ = try await CapturedBodyReader.read(kind: "response", source: missing); XCTFail("Missing later bytes cannot be labeled a complete read") }
        catch { XCTAssertTrue(error.localizedDescription.contains("incomplete")) }
        let unavailable = metadata(Data(), state: "expired")
        do {
            _ = try await CapturedBodyReader.read(kind: "response", source: CapturedBodySource(metadata: { unavailable }, page: { _ in XCTFail("Expired bodies must not be read"); return (Data(), 0) }))
            XCTFail("An expired capture cannot masquerade as an empty response")
        } catch { XCTAssertTrue(error.localizedDescription.contains("expired")) }
    }

    @MainActor func testCancellationStopsAtCurrentPageAndDoesNotPublishPartialDocument() async throws {
        let gate = BodyReadGate(), controller = CapturedBodyController()
        let bytes = Data(repeating: 97, count: 70_000), description = metadata(Data(repeating: 97, count: 70_000))
        var reads = 0
        let task = Task { await controller.load(kind: "response", source: CapturedBodySource(metadata: { description }, page: { offset in
            reads += 1
            await gate.wait()
            return (bytes.subdata(in: offset..<min(offset + 32_768, bytes.count)), bytes.count)
        })) }
        while !gate.entered { await Task.yield() }
        task.cancel(); gate.release(); await task.value
        XCTAssertEqual(reads, 1)
        XCTAssertNil(controller.document)
        XCTAssertFalse(controller.loading)
        XCTAssertTrue(controller.notice.isEmpty)
    }

    @MainActor func testLateResultCannotReplaceNewAttempt() async throws {
        let controller = CapturedBodyController(), gate = BodyReadGate()
        let old = Data(#"{"attempt":"old"}"#.utf8), latest = Data(#"{"attempt":"new"}"#.utf8)
        let oldMetadata = metadata(old)
        var initial = true
        let task = Task { await controller.load(kind: "request", source: CapturedBodySource(metadata: {
            if initial { initial = false; await gate.wait() }
            return oldMetadata
        }, page: { _ in (old, old.count) })) }
        while !gate.entered { await Task.yield() }
        await controller.load(kind: "request", source: source(latest))
        XCTAssertEqual(controller.document?.bytes, latest)
        gate.release(); await task.value
        XCTAssertEqual(controller.document?.bytes, latest, "Old reads must not overwrite the selected request")
        XCTAssertFalse(controller.loading)
    }

    @MainActor func testTreeChildrenAreLazyAndNativeRowsExpandAndCollapse() throws {
        let root = JSONOutlineNode(key: "$", value: ["items": Array(0..<5_000), "message": "Line one\nLine two 🌍"])
        XCTAssertEqual(root.cachedChildren, 0)
        let items = root.child(0)
        XCTAssertEqual(root.cachedChildren, 1)
        XCTAssertEqual(items.count, 5_000)
        XCTAssertEqual(items.cachedChildren, 0)
        XCTAssertEqual(items.child(4_999).detail, "4999")
        XCTAssertEqual(items.cachedChildren, 1, "A selected distant row must not eagerly construct thousands of children")
        XCTAssertEqual(root.child(1).detail, "Line one\nLine two 🌍")

        let coordinator = JSONOutlineView.Coordinator(selection: .constant(""))
        coordinator.root = JSONOutlineNode(key: "$", value: ["nested": ["value": true], "other": NSNull()])
        let outline = NSOutlineView()
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("key"))
        outline.addTableColumn(column); outline.outlineTableColumn = column
        outline.dataSource = coordinator; outline.delegate = coordinator
        outline.reloadData()
        XCTAssertEqual(outline.numberOfRows, 1)
        outline.expandItem(coordinator.root)
        XCTAssertEqual(outline.numberOfRows, 3)
        outline.expandItem(coordinator.root?.child(0))
        XCTAssertEqual(outline.numberOfRows, 4)
        outline.collapseItem(coordinator.root, collapseChildren: true)
        XCTAssertEqual(outline.numberOfRows, 1)
    }

    @MainActor func testArchiveReadLoadsLargeResponseAndPreservesHash() async throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("captured-body-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = PayloadArchive(root: root), attempt = UUID().uuidString
        let bytes = Data(("event: response.completed\ndata: " + String(repeating: "response 🌍 ", count: 20_000) + "\n\n").utf8)
        try await archive.configure(quota: 4_194_304, bodyRetention: 3600, metricRetention: 3600)
        var description: [String: WireValue] = ["attemptId": .string(attempt), "sessionId": .string("s"), "turnId": .string("t"), "mode": .string("persist"), "outcome": .string("running")]
        try await archive.begin(description, workspace: "w")
        for offset in stride(from: 0, to: bytes.count, by: 32_768) {
            try await archive.append(attempt: attempt, kind: "response", offset: offset, bytes: bytes.subdata(in: offset..<min(offset + 32_768, bytes.count)))
        }
        description["outcome"] = .string("completed")
        description["response"] = .object(["observedBytes": .number(Double(bytes.count))])
        try await archive.finish(description)
        let before = try await archive.metadata(attempt: attempt)
        let value = try await CapturedBodyReader.read(kind: "response", source: .archive(archive, attemptID: attempt, kind: "response"))
        XCTAssertEqual(value.bytes, bytes)
        XCTAssertEqual(value.metadata.hash, before["responseHash"])
        let after = try await archive.metadata(attempt: attempt)
        XCTAssertEqual(after, before, "Formatted presentation must never rewrite retained metadata or bytes")

        let gate = BodyReadGate()
        let cancelledRead = Task { try await archive.completeBody(attemptID: attempt, body: "response") { _, _ in await gate.wait() } }
        while !gate.entered { await Task.yield() }
        cancelledRead.cancel(); gate.release()
        do { _ = try await cancelledRead.value; XCTFail("Archive reads must cancel between chunks") }
        catch { XCTAssertTrue(error is CancellationError) }
        let database = try await archive.dashboardDatabase()
        try database.execute("UPDATE bodies SET digest=? WHERE attempt=? AND kind='response'", [.blob(Data(repeating: 0, count: 32)), .text(attempt)])
        do {
            _ = try await archive.completeBody(attemptID: attempt, body: "response")
            XCTFail("A complete-body read must also verify the whole-body digest")
        } catch { XCTAssertEqual(error.localizedDescription, CaptureFailure.corrupt.localizedDescription) }
    }

    @MainActor func testBoundsAndHexPreserveOriginalBytes() throws {
        XCTAssertEqual(CapturedBodyReader.limit("request"), 33_554_432)
        XCTAssertEqual(CapturedBodyReader.limit("response"), 67_108_864)
        for value in [-1.0, Double.nan, Double.infinity, 67_108_865, 1.5] {
            let metadata = CapturedBodyMetadata(body: ["retainedBytes": .number(value)], hash: nil)
            XCTAssertThrowsError(try metadata.count(limit: CapturedBodyReader.limit("response")))
        }
        XCTAssertEqual(try CapturedBodyHex.render(Data([0, 10, 127, 255])), "00000000  00 0a 7f ff \n")
        // Same dump, without one String(format:) call and one intermediate
        // string per sixteen bytes: a large body used to spin a core for it.
        let wide = Data((0..<(1 << 17)).map { UInt8(truncatingIfNeeded: $0) })
        let started = ProcessInfo.processInfo.systemUptime
        let dump = try CapturedBodyHex.render(wide)
        let elapsed = (ProcessInfo.processInfo.systemUptime - started) * 1000
        print("PERF hex dump of \(wide.count) bytes = \(String(format: "%.1f", elapsed)) ms")
        XCTAssertEqual(dump.prefix(34), "00000000  00 01 02 03 04 05 06 07 ")
        XCTAssertTrue(dump.contains("\n00010000  "), "offsets past 16 bits keep their eight hex digits")
        XCTAssertEqual(dump.filter { $0 == "\n" }.count, wide.count / 16)
    }

    @MainActor func testCaptureJSONViewerWhenRequested() async throws {
        guard let destination = testEnvironment("PI_APP_USAGE_CAPTURE_ROOT") else {
            throw XCTSkip("Set PI_APP_USAGE_CAPTURE_ROOT for the optional synthetic JSON viewer image")
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("body-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.traces.configure(quota: 4_194_304, bodyRetention: 3600, metricRetention: 3600)
        let attemptID = UUID().uuidString
        let bytes = Data(#"{"model":"auto-router","input":[{"role":"user","content":[{"type":"input_text","text":"Explain this request in plain language."}]}],"max_output_tokens":512,"reasoning":{"effort":"medium","summary":"auto"},"stream":true,"tools":[],"metadata":{"project":"Synthetic preview"}}"#.utf8)
        var description: [String: WireValue] = ["attemptId": .string(attemptID), "sessionId": .string("preview"), "turnId": .string("t"), "mode": .string("persist"), "outcome": .string("running")]
        try await model.traces.begin(description, workspace: "fixture")
        try await model.traces.append(attempt: attemptID, kind: "request", offset: 0, bytes: bytes)
        description["outcome"] = .string("completed")
        description["request"] = .object(["observedBytes": .number(Double(bytes.count))])
        try await model.traces.finish(description)
        var displayed = ""
        let view = VStack(alignment: .leading, spacing: 14) {
            Text("Captured request").font(PiFont.title())
            CapturedHeadersView(headers: ["content-type": .string("application/json"), "authorization": .string("Bearer ••••abcd")])
            CapturedBodyView(model: model, sessionID: "preview", attemptID: attemptID, kind: "request", retained: true,
                             displayedText: Binding(get: { displayed }, set: { displayed = $0 }))
        }.padding(24).background(Color.piContent)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 660), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        let hosted = NSHostingView(rootView: view); window.contentView = hosted
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.center(); window.orderFront(nil)
        let outline = try await renderedOutline(in: hosted, window: window)
        XCTAssertTrue(displayed.contains("auto-router"))
        let rootNode = try XCTUnwrap(outline.item(atRow: 0) as? JSONOutlineNode)
        let input = try XCTUnwrap((0..<rootNode.count).map { rootNode.child($0) }.first { $0.key == "input" })
        outline.expandItem(input); outline.expandItem(input.child(0))
        try await Task.sleep(for: .milliseconds(150))
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let image = try XCTUnwrap(create(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]))
        let folder = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg.write(to: folder.appendingPathComponent("captured-request-json.jpg"), options: .atomic)
    }

    @MainActor func testCaptureCombinedResponseViewerWhenRequested() async throws {
        guard let destination = testEnvironment("PI_APP_USAGE_CAPTURE_ROOT") else {
            throw XCTSkip("Set PI_APP_USAGE_CAPTURE_ROOT for the optional synthetic SSE response image")
        }
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("sse-preview-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let model = WorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { model.shutdown() }
        try await model.traces.configure(quota: 4_194_304, bodyRetention: 3600, metricRetention: 3600)
        let attemptID = UUID().uuidString
        let bytes = Data(("event: response.created\ndata: {\"type\":\"response.created\",\"response\":{\"model\":\"auto-router\"}}\n\n"
            + "event: response.completed\ndata: {\"type\":\"response.completed\",\"response\":{\"id\":\"resp_fixture\",\"model\":\"auto-router\",\"router_model_name\":\"gpt-5.4-mini\",\"status\":\"completed\",\"output\":[{\"type\":\"message\",\"role\":\"assistant\",\"content\":[{\"type\":\"output_text\",\"text\":\"The response is combined into one JSON object.\"}]}],\"usage\":{\"input_tokens\":38,\"output_tokens\":302,\"output_tokens_details\":{\"reasoning_tokens\":253},\"total_tokens\":340}}}\n\n"
            + "data: [DONE]\n\n").utf8)
        var description: [String: WireValue] = ["attemptId": .string(attemptID), "sessionId": .string("preview"), "turnId": .string("t"), "mode": .string("persist"), "outcome": .string("running")]
        try await model.traces.begin(description, workspace: "fixture")
        try await model.traces.append(attempt: attemptID, kind: "response", offset: 0, bytes: bytes)
        description["outcome"] = .string("completed")
        description["response"] = .object(["observedBytes": .number(Double(bytes.count))])
        try await model.traces.finish(description)
        var displayed = ""
        let view = VStack(alignment: .leading, spacing: 14) {
            Text("Captured response").font(PiFont.title())
            CapturedHeadersView(headers: ["content-type": .string("text/event-stream"), "x-litellm-model-name": .string("openai/gpt-5.4-mini")])
            CapturedBodyView(model: model, sessionID: "preview", attemptID: attemptID, kind: "response", retained: true,
                             displayedText: Binding(get: { displayed }, set: { displayed = $0 }), initialFormat: .combined)
        }.padding(24).background(Color.piContent)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 780), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.appearance = NSAppearance(named: .aqua)
        let hosted = NSHostingView(rootView: view); window.contentView = hosted
        defer { window.orderOut(nil); window.contentView = nil; window.close() }
        window.center(); window.orderFront(nil)
        let outline = try await renderedOutline(in: hosted, window: window)
        let copied = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(displayed.utf8)) as? [String: Any])
        XCTAssertEqual(copied["id"] as? String, "resp_fixture")
        XCTAssertTrue(displayed.contains("gpt-5.4-mini"))
        let rootNode = try XCTUnwrap(outline.item(atRow: 0) as? JSONOutlineNode)
        let output = try XCTUnwrap((0..<rootNode.count).map { rootNode.child($0) }.first { $0.key == "output" })
        outline.expandItem(output); outline.expandItem(output.child(0))
        let usage = try XCTUnwrap((0..<rootNode.count).map { rootNode.child($0) }.first { $0.key == "usage" })
        outline.expandItem(usage)
        let reasoning = try XCTUnwrap((0..<usage.count).map { usage.child($0) }.first { $0.key == "output_tokens_details" })
        outline.expandItem(reasoning)
        XCTAssertGreaterThanOrEqual(outline.numberOfRows, 16)
        try await Task.sleep(for: .milliseconds(150))
        hosted.layoutSubtreeIfNeeded(); window.displayIfNeeded()
        typealias ListImage = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        let symbol = try XCTUnwrap(dlsym(dlopen(nil, RTLD_NOW), "CGWindowListCreateImage"))
        let create = unsafeBitCast(symbol, to: ListImage.self)
        let image = try XCTUnwrap(create(.null, CGWindowListOption.optionIncludingWindow.rawValue, UInt32(window.windowNumber), CGWindowImageOption.boundsIgnoreFraming.rawValue)?.takeRetainedValue())
        let jpeg = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .jpeg, properties: [.compressionFactor: 0.82]))
        let folder = URL(fileURLWithPath: destination, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try jpeg.write(to: folder.appendingPathComponent("captured-response-combined.jpg"), options: .atomic)
    }
}

@MainActor private final class BodyReadGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func wait() async { await withCheckedContinuation { continuation = $0; entered = true } }
    func release() { continuation?.resume(); continuation = nil }
}
