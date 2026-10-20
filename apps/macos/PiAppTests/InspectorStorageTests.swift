import AppKit
import CryptoKit
import XCTest
@testable import PiApp

/// Generated retained captures, with the same refresh and copy controls as Raw.
@MainActor final class InspectorStorageTests: XCTestCase, SerialTestLane {
    private func fixture(withHeaders: Bool = true) async throws -> (URL, PayloadArchive, SessionInspectorModel, InspectorRawTab, NSWindow) {
        let root = scratchRoot("inspector-storage")
        let archive = PayloadArchive(root: root)
        try await archive.configure(quota: 8_388_608, bodyRetention: 86400, metricRetention: 86400)
        let id = UUID().uuidString, now = Date().timeIntervalSince1970
        let request = InspectorRequestModelTests.requestBody(2), response = InspectorRequestModelTests.stream(2, finished: true)
        var metadata: [String: WireValue] = ["attemptId": .string(id), "sessionId": .string("session"), "turnId": .string("turn"),
            "purpose": .string("turn"), "api": .string("openai-responses"), "requestedModel": .string("fixture"),
            "mode": .string("persist"), "outcome": .string("completed"), "wallTimestamp": .number(now),
            "timingVersion": .number(2), "timings": .object(["dispatch": .number(1)]),
            "requestHeaders": .object(["authorization": .string("Bearer ********-key"), "content-type": .string("application/json")]),
            "responseHeaders": .object(["content-type": .string("text/event-stream"), "x-request-id": .string("generated-request")])]
        if !withHeaders { metadata["requestHeaders"] = .object([:]); metadata["responseHeaders"] = .object([:]) }
        metadata["gateway"] = .object(["version": .number(1), "cost": .object(["status": .string("reported"), "usd": .number(1e-300)])])
        try await archive.begin(metadata, workspace: "project")
        try await archive.append(attempt: id, kind: "request", offset: 0, bytes: request)
        try await archive.append(attempt: id, kind: "response", offset: 0, bytes: response)
        metadata["request"] = .object(["observedBytes": .number(Double(request.count))])
        metadata["response"] = .object(["observedBytes": .number(Double(response.count))])
        try await archive.finish(metadata)
        let inspector = SessionInspectorModel(scope: .init(sessionID: "session", workspaceID: "project"), title: "Generated capture", archive: archive, workspace: nil,
                                              usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
        inspector.setVisible(true)
        try await eventually("the retained request index") { inspector.index.request(id) != nil }
        inspector.select(.request(id))
        try await eventually("the parsed request") { inspector.request.conversation.value != nil }
        inspector.request.tab = .response
        try await eventually("the parsed response") { inspector.request.response.value != nil }
        inspector.request.tab = .raw
        let raw = InspectorRawTab(inspector: inspector, request: inspector.request, compact: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = raw; window.orderFront(nil)
        try await eventually("the retained raw body") { self.copyButton(raw)?.isEnabled == true }
        return (root, archive, inspector, raw, window)
    }
    private func copyButton(_ raw: InspectorRawTab) -> PiKit.ButtonBase? {
        InspectorExpandFixture.descendants(PiKit.ButtonBase.self, in: raw).first { $0.accessibilityIdentifier() == "inspector-raw-copy" }
    }
    private func close(_ fixture: (URL, PayloadArchive, SessionInspectorModel, InspectorRawTab, NSWindow)) async {
        fixture.2.setVisible(false); fixture.4.close()
        try? await fixture.1.close(); try? FileManager.default.removeItem(at: fixture.0)
    }

    func testRedactedExportRefusesSelectionChangesAcrossCleanupAndQuestions() async throws {
        for stage in ["cleanup", "part", "format", "purge", "closed", "literal", "preview", "save"] { try await checkExport("redacted", changedAt: stage) }
    }

    func testMetadataExportRefusesSelectionChangesAcrossCleanupAndSave() async throws {
        for stage in ["cleanup", "save"] { try await checkExport("metadata", changedAt: stage) }
    }

    func testRetainedExportRefusesSelectionChangesAcrossCleanupAndQuestions() async throws {
        for stage in ["cleanup", "confirm", "save"] { try await checkExport("bodies", changedAt: stage) }
    }

    func testExportsKeepTheirSourceWhenSelectionIsUnchanged() async throws {
        for kind in ["metadata", "bodies", "redacted"] { try await checkExport(kind, changedAt: nil) }
    }

    func testRedactedExportSurvivesLossOfTheOtherBody() async throws {
        try await checkExport("redacted", changedAt: "other-purge")
    }

    func testMetadataExportNeverWritesAnUnloadedSource() async throws {
        let fixture = try await fixture(), inspector = fixture.2, request = inspector.request, raw = fixture.3
        defer { fixture.4.close() }
        addTeardownBlock { @MainActor in await self.close(fixture) }
        let workspace = makeWorkspaceModel(stateRoot: fixture.0.appendingPathComponent("workspace"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { workspace.shutdown() }
        inspector.workspace = workspace; request.workspace = workspace
        let metadataGate = AsyncGate(), collectionGate = AsyncGate()
        let recycling = Task<Void, Error> { await collectionGate.wait() }
        workspace.toolOutputRecycling = (UUID(), recycling)
        defer { workspace.toolOutputRecycling = nil; Task { await metadataGate.open(); await collectionGate.open() } }
        var row = try XCTUnwrap(request.row); row.id = "metadata-pending"
        request.metadataOverride = { _ in await metadataGate.wait(); return ["attemptId": .string("metadata-pending")] }
        request.open(row, predecessor: nil, previousLabel: nil); raw.refresh()
        XCTAssertTrue(request.metadataText.isEmpty)
        let destination = fixture.0.appendingPathComponent("metadata.json"), question = PiQuestion.shared, oldFiles = PiQuestion.shared.chooseFiles
        defer { question.chooseFiles = oldFiles }
        question.chooseFiles = { [destination] }
        let menu = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.MenuControl.self, in: raw).first { $0.accessibilityIdentifier() == "inspector-raw-menu" })
        let action = try XCTUnwrap(menu.entries().compactMap { if case .item(let item) = $0 { return item }; return nil }.first { $0.identifier == "inspector-export-metadata" })
        action.perform()
        try await eventually("the unloaded metadata export waiting for collection") { workspace.toolOutputProducers.values.contains(.export) }
        await metadataGate.open()
        try await eventually("metadata loading while export waits") { request.metadataLoaded }
        await collectionGate.open()
        try await eventually("the metadata export finishing") { workspace.toolOutputProducers.isEmpty }
        if FileManager.default.fileExists(atPath: destination.path) {
            let data = try Data(contentsOf: destination)
            XCTAssertFalse(data.isEmpty, "An unloaded source must not export an empty metadata file")
            let value = try? JSONDecoder().decode(WireValue.self, from: data)
            XCTAssertEqual(value?.object?["attemptId"]?.string, row.id)
        }
    }

    private func checkExport(_ kind: String, changedAt stage: String?) async throws {
        let fixture = try await fixture(), inspector = fixture.2, request = inspector.request, raw = fixture.3
        defer { fixture.4.close() }
        addTeardownBlock { @MainActor in await self.close(fixture) }
        let workspace = makeWorkspaceModel(stateRoot: fixture.0.appendingPathComponent("workspace"), vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { workspace.shutdown() }
        inspector.workspace = workspace; request.workspace = workspace
        let original = try XCTUnwrap(request.row), gate = AsyncGate()
        let recycling = Task<Void, Error> { await gate.wait() }
        workspace.toolOutputRecycling = (UUID(), recycling)
        defer { workspace.toolOutputRecycling = nil; Task { await gate.open() } }
        let destination = fixture.0.appendingPathComponent("export")
        if kind == "bodies" { try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true) }
        var questions = 0
        func changeSelection() {
            var other = original; other.id = "other-request"; other.sessionID = "other-session"
            request.sourceOverride = { _, _ in InspectorRequestModelTests.source({ Data("{\"text\":\"OTHER-REQUEST-BODY\"}".utf8) }) }
            request.metadataOverride = { _ in ["attemptId": .string(other.id), "sessionId": .string("other-session")] }
            request.open(other, predecessor: nil, previousLabel: nil); request.raw = .response; raw.refresh()
        }
        let question = PiQuestion.shared, oldAlert = question.answerAlert, oldFiles = question.chooseFiles
        defer { question.answerAlert = oldAlert; question.chooseFiles = oldFiles }
        question.answerAlert = { alert in
            questions += 1
            let current: String
            if let field = alert.accessoryView as? NSSecureTextField { field.stringValue = "message"; current = "literal" }
            else { current = alert.messageText == "Redacted view" ? "preview" : "confirm" }
            if stage == current { changeSelection() }
            return .alertFirstButtonReturn
        }
        question.chooseFiles = {
            questions += 1
            if stage == "save" { changeSelection() }
            return [destination]
        }
        let menu = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.MenuControl.self, in: raw).first { $0.accessibilityIdentifier() == "inspector-raw-menu" })
        let action = try XCTUnwrap(menu.entries().compactMap { if case .item(let item) = $0 { return item }; return nil }.first { $0.identifier == "inspector-export-" + kind })
        XCTAssertTrue(action.enabled); action.perform()
        try await eventually("the export waiting for collection") { workspace.toolOutputProducers.values.contains(.export) }
        if stage == "cleanup" {
            changeSelection()
            try await eventually("the new request's body") { request.metadataLoaded && self.copyButton(raw)?.isEnabled == true }
        } else if stage == "part" { request.raw = .response; raw.refresh() }
        else if stage == "format" { try XCTUnwrap(InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first).setFormat(.hex) }
        else if stage == "purge" { request.capturesCleared() }
        else if stage == "closed" { inspector.setVisible(false) }
        else if stage == "other-purge" {
            var metadata = request.metadata
            metadata["response"] = .object(["state": .string("purged"), "retainedBytes": .number(0)])
            let updated = metadata
            request.metadataOverride = { _ in updated }; request.refresh()
            try await eventually("the other capture expiring") { request.captureRevisions["response", default: 0] > 0 }
            raw.refresh(); XCTAssertTrue(copyButton(raw)?.isEnabled == true)
        }
        await gate.open()
        try await eventually("the export releasing its ownership") { workspace.toolOutputProducers.isEmpty }
        if let stage, stage != "other-purge" {
            if ["cleanup", "part", "format", "purge", "closed"].contains(stage) { XCTAssertEqual(questions, 0, "\(kind) must refuse a changed selection before opening an export question") }
            if kind == "bodies" { XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty) }
            else { XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path), "\(kind) exported a changed selection after \(stage)") }
        } else if kind == "bodies" {
            XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty)
        } else {
            let value = try JSONDecoder().decode(WireValue.self, from: Data(contentsOf: destination)).object
            XCTAssertEqual(value?["attemptId"]?.string, original.id)
            if kind == "redacted" {
                XCTAssertEqual(value?["sourceView"]?.string, "request")
                XCTAssertTrue(value?["view"]?.string?.contains("[REDACTED] 0") == true)
            }
        }
    }

    func testClearThenRefreshRetiresLoadedBodiesWithoutNavigation() async throws {
        let fixture = try await fixture(), archive = fixture.1, inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        let copy = try XCTUnwrap(copyButton(raw))
        NSPasteboard.general.clearContents(); copy.performClick(nil)
        try await eventually("the captured body copy") { NSPasteboard.general.string(forType: .string)?.contains("message 0") == true }
        try await archive.clear(sessionID: "session")
        inspector.refresh()
        try await eventually("the purged descriptor") { inspector.request.metadata["request"]?.object?["state"]?.string == "purged" }
        XCTAssertEqual(inspector.request.metadata["request"]?.object?["retainedBytes"]?.number, 0)
        XCTAssertEqual(inspector.request.metadata["response"]?.object?["state"]?.string, "purged")
        XCTAssertEqual(inspector.request.metadata["response"]?.object?["retainedBytes"]?.number, 0)
        XCTAssertNil(inspector.request.conversation.value); XCTAssertNil(inspector.request.response.value)
        try await eventually("the purged copy source") { !copy.isEnabled }
        XCTAssertNil(InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first?.controller.document)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("after clear", forType: .string)
        copy.performClick(nil)
        await Task.yield()
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "after clear")
        inspector.request.raw = .response; raw.refresh()
        XCTAssertFalse(copy.isEnabled, "The other body must not restore its old copy source")
    }

    func testRefreshPreservesAnUnchangedRawDocumentAndFormat() async throws {
        let fixture = try await fixture(), inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        let body = try XCTUnwrap(InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first)
        body.setFormat(.hex)
        let document = try XCTUnwrap(body.controller.document?.id)
        let reads = inspector.indexReads
        inspector.refresh()
        try await eventually("the explicit refresh") { inspector.indexReads > reads && inspector.request.metadataLoaded }
        raw.refresh()
        let refreshed = try XCTUnwrap(InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first)
        XCTAssertTrue(refreshed === body)
        XCTAssertEqual(refreshed.format, .hex)
        XCTAssertEqual(refreshed.controller.document?.id, document)
    }

    func testSessionMemoryCompletionKeepsRawStateAndOffersTheLatestResponse() async throws {
        try await checkMemoryCompletion(omittedRequest: false)
    }

    func testCredentialOmittedRequestCompletionPreservesReadableResponse() async throws {
        try await checkMemoryCompletion(omittedRequest: true)
    }

    func testCompletedMemoryCaptureExportsBodiesAndReadsHelperEvents() async throws {
        try await checkCompletedCaptureActions(mode: "memory")
    }

    func testCompletedOffCaptureReadsHelperEventsWithoutInventingBodies() async throws {
        try await checkCompletedCaptureActions(mode: "off")
    }

    func testCompletedPersistedCaptureActionsUseTheArchive() async throws {
        try await checkCompletedCaptureActions(mode: "persist")
    }

    func testMemoryCaptureActionsSurviveMetricExpiry() async throws {
        try await checkCompletedCaptureActions(mode: "memory", expireMetrics: true)
    }

    func testPersistedCaptureActionsSurviveHelperShutdown() async throws {
        try await checkCompletedCaptureActions(mode: "persist", stopHelper: true)
    }

    func testEventsFollowTheArchiveHandoffDuringTheRead() async throws {
        try await checkCompletedCaptureActions(mode: "persist", handoff: "events")
    }

    func testExportFollowsTheArchiveHandoffDuringTheRead() async throws {
        try await checkCompletedCaptureActions(mode: "persist", handoff: "export")
    }

    func testMemoryExportKeepsItsSessionWhenSelectionChangesInTheChooser() async throws {
        try await checkCompletedCaptureActions(mode: "memory", navigateOnExport: true)
    }

    func testMemoryExportDoesNotClaimSuccessWhenOwnershipLookupFails() async throws {
        try await checkCompletedCaptureActions(mode: "memory", probeFailure: true)
    }

    func testPersistedExportRemainsReadableWhenOwnershipLookupFails() async throws {
        try await checkCompletedCaptureActions(mode: "persist", probeFailure: true)
    }

    func testExportRechecksHandoffAfterTheLastBodyRead() async throws {
        try await checkCompletedCaptureActions(mode: "persist", handoff: "export-verified")
    }

    func testExportRechecksHandoffWhenVerificationRecordWasPruned() async throws {
        try await checkCompletedCaptureActions(mode: "persist", handoff: "export-pruned")
    }

    func testExportRechecksHandoffWhenBodyRecordWasPruned() async throws {
        try await checkCompletedCaptureActions(mode: "persist", handoff: "export-pruned-read")
    }

    func testEventsRecheckHandoffWhenHelperRecordWasPruned() async throws {
        try await checkCompletedCaptureActions(mode: "persist", handoff: "events-pruned")
    }

    func testChangedMemoryExportDoesNotRetryAnEmptyArchive() async throws {
        try await checkCompletedCaptureActions(mode: "memory", handoff: "export-changed-memory")
    }

    func testPrunedMemoryExportDoesNotRetryAnEmptyArchive() async throws {
        try await checkCompletedCaptureActions(mode: "memory", handoff: "export-pruned")
    }

    private func checkCompletedCaptureActions(mode: String, expireMetrics: Bool = false, stopHelper: Bool = false,
                                              handoff: String? = nil, navigateOnExport: Bool = false, probeFailure: Bool = false) async throws {
        let root = scratchRoot("inspector-capture-actions")
        let workspace = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        let archive = workspace.traces, id = UUID().uuidString
        addTeardownBlock { @MainActor in
            workspace.shutdown(); try? await archive.close()
            try? FileManager.default.removeItem(at: await workspace.liveExporter.root); try? FileManager.default.removeItem(at: root)
        }
        workspace.chats = [ChatRecord(id: "child", workspaceID: "project", title: "Generated child", profileID: "fixture")]
        try await archive.configure(quota: nil, bodyRetention: 86400, metricRetention: 86400)
        let input = InspectorRequestModelTests.requestBody(600), output = InspectorRequestModelTests.stream(300, finished: true)
        let events: [WireValue] = (0..<260).map { .object(["type": .string("response.output_text.delta"), "start": .number(Double($0)), "end": .number(Double($0 + 1)), "observedAt": .number(Double($0))]) }
        var metadata: [String: WireValue] = ["attemptId": .string(id), "sessionId": .string("child"), "turnId": .string("turn"),
            "purpose": .string("turn"), "api": .string("openai-responses"), "mode": .string(mode), "outcome": .string("running")]
        if expireMetrics { metadata["wallTimestamp"] = .number(Date().timeIntervalSince1970 - 2 * 86400) }
        for (kind, bytes) in [("request", input), ("response", output)] {
            metadata[kind] = .object(["state": .string(mode == "off" ? "not-captured" : "complete"), "observedBytes": .number(Double(bytes.count)),
                                     "retainedBytes": .number(mode == "off" ? 0 : Double(bytes.count)), "savedToLog": .bool(false)])
        }
        try await archive.begin(metadata, workspace: "project")
        if mode == "persist" {
            for (kind, bytes) in [("request", input), ("response", output)] {
                for offset in stride(from: 0, to: bytes.count, by: 32_768) {
                    try await archive.append(attempt: id, kind: kind, offset: offset, bytes: Data(bytes.dropFirst(offset).prefix(32_768)))
                }
            }
            for offset in stride(from: 0, to: events.count, by: 128) {
                try await archive.accept(["type": .string("events"), "attemptId": .string(id), "offset": .number(Double(offset)),
                                          "events": .array(Array(events.dropFirst(offset).prefix(128)))], workspace: "project")
            }
        }
        var commands: [[String: WireValue]] = [], host: HostSupervisor!, handoffs = 0, failProbe = false, pruned = false
        func markSaved(_ saved: Bool) {
            for kind in ["request", "response"] {
                var descriptor = metadata[kind]!.object!; descriptor["savedToLog"] = .bool(saved); metadata[kind] = .object(descriptor)
                let bytes = kind == "request" ? input : output
                metadata[kind + "Hash"] = saved || mode == "off" ? .null : .object(["sha256": .string(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined())])
            }
        }
        markSaved(false)
        host = HostSupervisor(commandSender: { frame in
            commands.append(frame)
            XCTAssertEqual(frame["sessionId"]?.string, "child", "Use the selected request's physical session, never the Inspector owner")
            XCTAssertEqual(frame["params"]?.object?["attemptId"]?.string, id)
            let params = frame["params"]?.object ?? [:], offset = Int(params["offset"]?.number ?? 0)
            if handoffs == 0, (handoff == "events-pruned" && frame["method"]?.string == "debug.raw-events") ||
                (handoff == "export-pruned-read" && frame["method"]?.string == "debug.body") {
                handoffs += 1; markSaved(true); pruned = true
            }
            if pruned {
                host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(host.epoch!),
                                     "commandId": frame["commandId"]!, "ok": .bool(false),
                                     "result": .object(["code": .string("capture_unavailable"), "message": .string("Generated helper record was pruned")])]), connectionID: host.connectionID!)
                return
            }
            if failProbe, frame["method"]?.string == "debug.attempt" {
                host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(host.epoch!),
                                     "commandId": frame["commandId"]!, "ok": .bool(false),
                                     "result": .object(["code": .string("fixture_failure"), "message": .string("Generated ownership lookup failure")])]), connectionID: host.connectionID!)
                return
            }
            if handoffs == 0, (handoff == "events" && frame["method"]?.string == "debug.raw-events") || (handoff == "export" && frame["method"]?.string == "debug.body") {
                handoffs += 1; markSaved(true)
                host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(host.epoch!),
                                     "commandId": frame["commandId"]!, "ok": .bool(false),
                                     "result": .object(["code": .string("capture_saved"), "message": .string("Read the saved capture in the archive")])]), connectionID: host.connectionID!)
                return
            }
            let result: [String: WireValue]
            switch frame["method"]?.string {
            case "debug.attempt": result = metadata
            case "debug.raw-events":
                XCTAssertNotEqual(mode, "persist", "Acknowledged persisted event indices live in the archive")
                result = ["events": .array(Array(events.dropFirst(offset).prefix(128))), "total": .number(Double(events.count)), "response": metadata["response"]!]
            case "debug.body":
                let bytes = params["body"]?.string == "request" ? input : output
                XCTAssertNotEqual(mode, "off", "Off has no readable body")
                XCTAssertFalse(metadata["response"]?.object?["savedToLog"]?.bool == true, "Saved helper buffers have been released")
                result = ["bytes": .string(Data(bytes.dropFirst(offset).prefix(32_768)).base64EncodedString()), "retainedBytes": .number(Double(bytes.count))]
                if handoffs == 0, params["body"]?.string == "response", offset + 32_768 >= output.count,
                   ["export-verified", "export-pruned", "export-changed-memory"].contains(handoff ?? "") {
                    handoffs += 1
                    if mode == "persist" { markSaved(true) }
                    else {
                        var descriptor = metadata["response"]!.object!; descriptor["reason"] = .string("Generated descriptor change")
                        metadata["response"] = .object(descriptor)
                    }
                    pruned = handoff == "export-pruned"
                }
            default: XCTFail("Unexpected generated command: \(frame)"); result = [:]
            }
            host.receive(.frame(["v": .number(1), "kind": .string("reply"), "hostEpoch": .string(host.epoch!),
                                 "commandId": frame["commandId"]!, "ok": .bool(true), "result": .object(result)]), connectionID: host.connectionID!)
        })
        addTeardownBlock { @MainActor in try? await host.shutdownAndWait(); host = nil }
        try await host.connect(cwd: root, state: root.appendingPathComponent("generated-host"))
        workspace.hosts["project"] = host
        let inspector = SessionInspectorModel(scope: .init(sessionID: "parent", workspaceID: "project"), title: "Generated child capture", archive: archive, workspace: workspace,
                                              usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
        let request = inspector.request
        request.tab = .raw
        let live = InspectorRequestRow(id: id, wall: 1, sessionID: "child", turn: "turn", purpose: "turn", api: "openai-responses", outcome: "running", source: .live)
        request.open(live, predecessor: nil, previousLabel: nil); request.setActive(true)
        try await eventually("live capture metadata") { request.metadataLoaded }
        metadata["outcome"] = .string("completed")
        try await archive.finish(metadata)
        if mode == "persist" { markSaved(!(handoff?.hasPrefix("events") ?? false)) }
        let saved = try await archive.inspectorRows(sessionID: "child", workspaceID: "project")
        let merged = try XCTUnwrap(InspectorIndex.merge(durable: saved.rows, live: [live]).first)
        XCTAssertEqual(merged.source, .log)
        request.open(merged, predecessor: nil, previousLabel: nil)
        try await eventually("completed archive metadata") { request.metadataLoaded && request.metadata["outcome"]?.string == "completed" }
        if expireMetrics { XCTAssertNil(request.metadata["mode"], "Expired metadata no longer describes the original capture mode") }
        if stopHelper { try await host.shutdownAndWait(); workspace.hosts.removeValue(forKey: "project") }
        request.raw = .events
        let raw = InspectorRawTab(inspector: inspector, request: request, compact: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = raw; window.orderFront(nil)
        addTeardownBlock { @MainActor in
            PiQuestion.shared.answerAlert = nil; PiQuestion.shared.chooseFiles = nil
            request.setActive(false); window.contentView = nil; window.close()
        }
        do { try await eventually("the Events page", timeout: .seconds(3)) { self.copyButton(raw)?.isEnabled == true } }
        catch { return }
        func eventPage() throws -> [String: WireValue] {
            let text = try XCTUnwrap(InspectorExpandFixture.descendants(PagedTextView.self, in: raw).first?.text)
            return try JSONDecoder().decode([String: WireValue].self, from: Data(text.utf8))
        }
        XCTAssertEqual(try eventPage()["total"]?.number, Double(events.count))
        XCTAssertEqual(try eventPage()["events"]?.array, Array(events.prefix(128)))
        if let pager = InspectorExpandFixture.descendants(PiKit.Pager.self, in: raw).first {
            pager.next.performClick(nil)
            try await eventually("the second Events page") { (try? eventPage()["events"]?.array) == Array(events.dropFirst(128).prefix(128)) }
        } else { XCTFail("The helper's retained Events must have a second page") }
        let destination = root.appendingPathComponent("export")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        PiQuestion.shared.answerAlert = { _ in .alertFirstButtonReturn }
        PiQuestion.shared.chooseFiles = {
            failProbe = probeFailure
            if handoff?.hasPrefix("export") == true { markSaved(false) }
            if navigateOnExport {
                request.setActive(false); request.raw = .metadata
                var sibling = merged; sibling.id = UUID().uuidString; sibling.sessionID = "sibling"
                request.open(sibling, predecessor: nil, previousLabel: nil)
            }
            return [destination]
        }
        let menu = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.MenuControl.self, in: raw).first { $0.accessibilityIdentifier() == "inspector-raw-menu" })
        XCTAssertTrue(PiMenus.perform("inspector-export-bodies", in: PiMenus.menu(menu.entries())))
        let exported = destination.appendingPathComponent(id)
        if mode == "memory", probeFailure || handoff != nil {
            let expected = probeFailure ? "Generated ownership lookup failure" : handoff == "export-pruned" ? "Generated helper record was pruned" : TraceError.changed.localizedDescription
            func reportedFailure() -> Bool { InspectorExpandFixture.descendants(PiKit.Note.self, in: raw).contains { $0.text == expected } }
            try await eventually("the export result") { reportedFailure() || FileManager.default.fileExists(atPath: exported.path) }
            XCTAssertFalse(FileManager.default.fileExists(atPath: exported.path), "A failed ownership query cannot publish a successful empty memory export")
            XCTAssertTrue(reportedFailure())
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: destination.path).isEmpty, "Failed transfer staging must be removed")
            if handoff != nil { XCTAssertEqual(handoffs, 1) }
            return
        }
        do { try await eventually("the export manifest", timeout: .seconds(3)) { FileManager.default.fileExists(atPath: exported.appendingPathComponent("manifest.json").path) } }
        catch { return }
        for (kind, expected) in [("request", input), ("response", output)] {
            let file = exported.appendingPathComponent(kind + ".bin")
            XCTAssertEqual(FileManager.default.fileExists(atPath: file.path), mode != "off", "\(mode) \(kind) export availability")
            if mode != "off", FileManager.default.fileExists(atPath: file.path) { XCTAssertEqual(try Data(contentsOf: file), expected) }
        }
        if handoff != nil { XCTAssertEqual(handoffs, 1) }
        if mode != "off", !expireMetrics, !navigateOnExport, !probeFailure, !stopHelper, handoff == nil, let path = testEnvironment("PI_APP_INSPECTOR_STORAGE_GALLERY") {
            let folder = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let canvas = FillView(.piContent)
            window.contentView = canvas; canvas.addSubview(raw); raw.frame = canvas.bounds; raw.autoresizingMask = [.width, .height]
            await Task.yield()
            try await eventually("the gallery Events page") { self.copyButton(raw)?.isEnabled == true }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                for width in [1000, 700, 485] {
                    raw.compact = width < 900; window.setContentSize(NSSize(width: width, height: 600))
                    try capture(canvas, to: folder.appendingPathComponent("\(mode)-events-export-\(name)-\(width).png"))
                }
            }
        }
        XCTAssertFalse(commands.isEmpty)
    }

    private func checkMemoryCompletion(omittedRequest: Bool) async throws {
        let root = scratchRoot("inspector-memory-completion")
        let workspace = makeWorkspaceModel(stateRoot: root, vault: ConfigurationVault(storage: MemoryVaultStorage()))
        defer { workspace.shutdown(); try? FileManager.default.removeItem(at: root) }
        let archive = workspace.traces
        try await archive.configure(quota: 8_388_608, bodyRetention: 86400, metricRetention: 86400)
        for part in omittedRequest ? [.response] : [InspectorRequestModel.RawPart.request, .response] {
            let inspector = SessionInspectorModel(scope: .init(sessionID: "session", workspaceID: "project"), title: "Memory capture", archive: archive, workspace: workspace,
                                                  usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
            let request = inspector.request
            let input = InspectorRequestModelTests.requestBody(2)
            let prefix = InspectorRequestModelTests.stream(2), complete = InspectorRequestModelTests.stream(20, finished: true)
            var finished = false
            request.sourceOverride = { _, kind in
                if kind == "request", omittedRequest { return InspectorRequestModelTests.source({ Data() }, state: { "credential-omitted" }) }
                return InspectorRequestModelTests.source({ kind == "request" ? input : finished ? complete : prefix },
                                                  state: { kind == "request" || finished ? "complete" : "partial" })
            }
            request.metadataOverride = { row in
                if row.source != .live { return try await archive.metadata(attempt: row.id) }
                return ["outcome": .string("running"),
                        "request": .object(["state": .string(omittedRequest ? "credential-omitted" : "complete"), "retainedBytes": .number(omittedRequest ? 0 : Double(input.count))]),
                        "response": .object(["state": .string("partial"), "retainedBytes": .number(Double(prefix.count))])]
            }
            let live = InspectorRequestRow(id: UUID().uuidString, wall: 1, turn: "t", purpose: "turn", api: "openai-responses", alias: "fixture", model: "fixture", outcome: "running", source: .live)
            request.tab = .response; request.open(live, predecessor: nil, previousLabel: nil); request.setActive(true)
            defer { request.setActive(false) }
            try await eventually("the memory response prefix") { request.response.value?.partial == true }
            let parsedBytes = request.responseBytes, reads = request.bodyReads, revision = request.captureRevisions
            request.tab = .raw; request.raw = part; request.query = "word"
            let raw = InspectorRawTab(inspector: inspector, request: request, compact: false)
            let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false; window.contentView = raw; window.orderFront(nil)
            defer { window.contentView = nil; window.close() }
            try await eventually("the memory raw body") { self.copyButton(raw)?.isEnabled == true }
            let body = try XCTUnwrap(InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first)
            body.setFormat(.hex)
            let document = try XCTUnwrap(body.controller.document?.id)
            let metadata: [String: WireValue] = ["attemptId": .string(live.id), "sessionId": .string("session"), "turnId": .string("t"),
                "mode": .string("memory"), "outcome": .string("completed"), "api": .string("openai-responses"),
                "request": .object(["observedBytes": .number(Double(input.count))]), "response": .object(["observedBytes": .number(Double(complete.count))])]
            try await archive.begin(metadata, workspace: "project"); try await archive.finish(metadata)
            var durable = live; durable.source = .log; durable.outcome = "completed"
            let merged = try XCTUnwrap(InspectorIndex.merge(durable: [durable], live: [live]).first)
            XCTAssertEqual(merged.source, .log)
            finished = true; request.open(merged, predecessor: nil, previousLabel: nil)
            try await eventually("the completed memory metadata") { request.metadata["outcome"]?.string == "completed" && request.metadataText.contains("not-retained") }
            raw.refresh()
            XCTAssertEqual(request.captureRevisions, revision, "A durable row without durable bytes is not a purge")
            XCTAssertEqual(request.metadata["response"]?.object?["state"]?.string, "not-retained")
            let shown = try XCTUnwrap(InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first)
            XCTAssertTrue(shown === body)
            XCTAssertEqual(shown.format, .hex); XCTAssertEqual(shown.controller.document?.id, document)
            XCTAssertEqual(shown.searchQuery, "word")
            XCTAssertEqual(request.response.value?.partial, true); XCTAssertEqual(request.responseBytes, parsedBytes)
            XCTAssertEqual(request.bodyReads, reads)
            XCTAssertEqual(request.growingBytes, complete.count, "Load latest uses the readable memory source")
            request.tab = .response
            await Task.yield()
            XCTAssertEqual(request.response.value?.partial, true, "Opening Response keeps the chosen prefix")
            request.loadLatest()
            try await eventually("the explicitly requested final response") { request.response.value?.partial == false }
            XCTAssertEqual(request.responseBytes, complete.count)
        }
        XCTAssertTrue(workspace.hosts.isEmpty, "Generated sources never start a helper")
        try await archive.close()
    }

    func testCaptureOffStreamingKeepsRawLinksPagination() async throws {
        let root = scratchRoot("inspector-off-links")
        let archive = PayloadArchive(root: root)
        let inspector = SessionInspectorModel(scope: .init(sessionID: "session", workspaceID: "project"), title: "Capture Off", archive: archive, workspace: nil,
                                              usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
        let request = inspector.request, id = UUID().uuidString
        addTeardownBlock { @MainActor in
            request.setActive(false); try? await archive.close(); try? FileManager.default.removeItem(at: root)
        }
        try await archive.configure(quota: 8_388_608, bodyRetention: 86400, metricRetention: 86400)
        try await archive.begin(["attemptId": .string(id), "sessionId": .string("session"), "turnId": .string("t"),
                                 "purpose": .string("turn"), "api": .string("openai-responses"), "requestedModel": .string("fixture"),
                                 "mode": .string("off"), "outcome": .string("running"),
                                 "messageIds": .array((0..<260).map { .string(String(format: "context-%03d", $0)) })], workspace: "project")
        var observed = 10, polls = 0
        request.metadataPollInterval = .milliseconds(40)
        request.metadataOverride = { _ in
            polls += 1
            return ["outcome": .string("streaming"),
                    "request": .object(["state": .string("not-captured"), "observedBytes": .number(10), "retainedBytes": .number(0)]),
                    "response": .object(["state": .string("not-captured"), "observedBytes": .number(Double(observed)), "retainedBytes": .number(0)])]
        }
        request.sourceOverride = { _, _ in nil }
        request.tab = .raw; request.raw = .links
        request.open(InspectorRequestRow(id: id, wall: 1, turn: "t", purpose: "turn", api: "openai-responses", alias: "fixture", model: "fixture", outcome: "streaming", source: .live), predecessor: nil, previousLabel: nil)
        request.setActive(true)
        let raw = InspectorRawTab(inspector: inspector, request: request, compact: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = raw; window.orderFront(nil)
        addTeardownBlock { @MainActor in
            window.contentView = nil; window.close()
        }
        try await eventually("the first links page") { InspectorExpandFixture.descendants(PiKit.Pager.self, in: raw).first != nil && request.metadataLoaded }
        let pager = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.Pager.self, in: raw).first)
        pager.next.performClick(nil)
        try await eventually("the second links page") { InspectorExpandFixture.descendants(PagedTextView.self, in: raw).first?.text.hasPrefix("context  context-128") == true }
        let page = try XCTUnwrap(InspectorExpandFixture.descendants(PagedTextView.self, in: raw).first?.text)
        let revision = request.captureRevisions, previousPolls = polls
        observed = 100
        try await eventually("several Off metadata polls") { polls >= previousPolls + 3 && request.metadata["response"]?.object?["observedBytes"]?.number == 100 }
        raw.refresh()
        XCTAssertEqual(request.captureRevisions, revision, "Changing observed bytes never makes an unavailable body disappear")
        XCTAssertTrue(InspectorExpandFixture.descendants(PagedTextView.self, in: raw).first?.text == page, "Links must stay on rows 129–256")
        let copy = try XCTUnwrap(copyButton(raw)); NSPasteboard.general.clearContents(); copy.performClick(nil)
        XCTAssertTrue(NSPasteboard.general.string(forType: .string) == page, "Copy must still use the selected links page")
        request.capturesCleared(); raw.refresh()
        XCTAssertTrue(InspectorExpandFixture.descendants(PagedTextView.self, in: raw).first?.text == page, "Clearing bodies does not clear message links or their selected page")
    }

    func testLosingOneBodyPreservesTheOtherDocumentAndCopySource() async throws {
        for lost in ["request", "response"] {
            let fixture = try await fixture(), request = fixture.2.request, raw = fixture.3
            addTeardownBlock { @MainActor in await self.close(fixture) }
            request.raw = lost == "request" ? .response : .request; raw.refresh()
            try await eventually("the other raw body") { self.copyButton(raw)?.isEnabled == true }
            let body = try XCTUnwrap(InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first)
            body.setFormat(.hex)
            let document = try XCTUnwrap(body.controller.document?.id), reads = request.bodyReads
            var metadata = request.metadata
            metadata[lost] = .object(["state": .string("purged"), "retainedBytes": .number(0)])
            let updated = metadata
            request.metadataOverride = { _ in updated }
            request.sourceOverride = { row, kind in
                kind == lost ? InspectorRequestModelTests.source({ Data() }, state: { "purged" }) : .archive(fixture.1, attemptID: row.id, kind: kind)
            }
            request.refresh()
            try await eventually("one purged descriptor") { request.metadata[lost]?.object?["state"]?.string == "purged" && request.metadataLoaded }
            raw.refresh()
            let shown = try XCTUnwrap(InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first)
            XCTAssertTrue(shown === body); XCTAssertEqual(shown.format, .hex); XCTAssertEqual(shown.controller.document?.id, document)
            XCTAssertEqual(request.bodyReads, reads)
            XCTAssertTrue(copyButton(raw)?.isEnabled == true, "The other body's copy source remains readable")
            if lost == "request" {
                XCTAssertNil(request.conversation.value); XCTAssertNotNil(request.response.value)
            } else {
                XCTAssertNil(request.response.value); XCTAssertNotNil(request.conversation.value)
            }
        }
    }

    func testRawBodyReadBeforeFirstMetadataStillRetiresWhenLost() async throws {
        try await checkFirstMetadata(parsePending: false)
    }

    func testPurgeDuringFirstRawParseCannotPublishTheBody() async throws {
        try await checkFirstMetadata(parsePending: true)
    }

    private func checkFirstMetadata(parsePending: Bool) async throws {
        let entered = DispatchSemaphore(value: 0), unblock = DispatchSemaphore(value: 0)
        let held: Task<Void, Error>? = parsePending ? Task { try await CapturedBodyWorker.shared.run { entered.signal(); unblock.wait() } } : nil
        defer { unblock.signal() }
        if parsePending { try await eventually("the held body parser") { entered.wait(timeout: .now()) == .success } }
        let root = scratchRoot("inspector-first-metadata"), prefix = InspectorRequestModelTests.stream(2)
        let archive = PayloadArchive(root: root)
        let inspector = SessionInspectorModel(scope: .init(sessionID: "session", workspaceID: "project"), title: "Pending metadata", archive: archive, workspace: nil,
                                              usageLoader: { _, _, _ in throw CaptureFailure.unavailable }, cache: InspectorDocumentCache())
        let request = inspector.request
        var available = true, descriptions = 0, release: CheckedContinuation<Void, Never>?
        request.metadataOverride = { _ in
            await withCheckedContinuation { release = $0 }
            return ["outcome": .string("completed"), "response": .object(["state": .string("purged"), "retainedBytes": .number(0)])]
        }
        request.sourceOverride = { _, _ in
            let source = InspectorRequestModelTests.source({ available ? prefix : Data() }, state: { available ? "partial" : "purged" })
            return CapturedBodySource(metadata: { descriptions += 1; return try await source.metadata() }, page: source.page)
        }
        request.tab = .raw; request.raw = .response
        request.open(InspectorRequestRow(id: UUID().uuidString, wall: 1, turn: "t", purpose: "turn", api: "openai-responses", alias: "fixture", model: "fixture", outcome: "completed", source: .log), predecessor: nil, previousLabel: nil)
        request.setActive(true)
        let raw = InspectorRawTab(inspector: inspector, request: request, compact: false)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1000, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false; window.contentView = raw; window.orderFront(nil)
        defer { request.setActive(false); release?.resume(); window.contentView = nil; window.close(); try? FileManager.default.removeItem(at: root) }
        try await eventually("Raw before its first metadata record") { (parsePending ? descriptions >= 2 : self.copyButton(raw)?.isEnabled == true) && release != nil }
        XCTAssertFalse(request.metadataLoaded)
        available = false; release?.resume(); release = nil
        try await eventually("the first unavailable descriptor") { request.metadataLoaded }
        raw.refresh()
        if parsePending {
            unblock.signal(); try await held?.value; try await CapturedBodyWorker.shared.run { }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertFalse(copyButton(raw)?.isEnabled == true, "The body read itself establishes prior availability")
        XCTAssertNil(InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first?.controller.document)
    }

    func testClearingResponseRetiresItsRawEventIndex() async throws {
        let fixture = try await fixture(), archive = fixture.1, inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        let id = try XCTUnwrap(inspector.request.row?.id)
        let event: WireValue = .object(["type": .string("generated-event-purge"), "start": .number(0), "end": .number(10), "observedAt": .number(1)])
        try await archive.accept(["type": .string("events"), "attemptId": .string(id), "offset": .number(0), "events": .array([event])], workspace: "project")
        inspector.request.raw = .events; raw.refresh()
        try await eventually("the retained event index") { InspectorExpandFixture.descendants(PagedTextView.self, in: raw).first?.text.contains("generated-event-purge") == true }
        try await archive.clear(sessionID: "session"); inspector.refresh()
        try await eventually("the response purge") { inspector.request.metadata["response"]?.object?["state"]?.string == "purged" }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("after clear", forType: .string)
        inspector.request.capturesCleared(); copyButton(raw)?.performClick(nil)
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "after clear", "Even before Raw refreshes, a retired event index cannot be copied")
        raw.refresh()
        XCTAssertFalse(InspectorExpandFixture.descendants(PagedTextView.self, in: raw).first?.text.contains("generated-event-purge") == true, "Events belong to the retired response, unlike message links")
        NSPasteboard.general.clearContents(); copyButton(raw)?.performClick(nil)
        XCTAssertFalse(NSPasteboard.general.string(forType: .string)?.contains("generated-event-purge") == true)
    }

    func testRawToolbarFitsEveryPartAtNarrowAndMinimumPaneWidths() async throws {
        let fixture = try await fixture(), request = fixture.2.request, raw = fixture.3, window = fixture.4
        addTeardownBlock { @MainActor in await self.close(fixture) }
        // The minimum 700-point window reserves 214 points plus its rule for the navigator.
        let minimumPane = SessionInspectorWindowController.minimumSize.width - 215
        for width in [1000, 740, 700, minimumPane] as [CGFloat] {
            window.setContentSize(NSSize(width: width, height: 600)); raw.compact = width < 900
            for part in InspectorRequestModel.RawPart.allCases {
                request.raw = part; raw.refresh(); raw.layoutSubtreeIfNeeded()
                let copy = try XCTUnwrap(copyButton(raw))
                let menu = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.MenuControl.self, in: raw).first { $0.accessibilityIdentifier() == "inspector-raw-menu" })
                var controls: [NSView] = [copy, menu]
                if let parts = InspectorExpandFixture.descendants(PiKit.Tabs<InspectorRequestModel.RawPart>.self, in: raw).first { controls.append(parts) }
                if let parts = InspectorExpandFixture.descendants(PiKit.MenuButton.self, in: raw).first(where: { $0.accessibilityIdentifier() == "inspector-raw-parts-menu" }) {
                    controls.append(parts)
                    let entries = parts.entries().compactMap { if case .item(let item) = $0 { return item }; return nil }
                    XCTAssertEqual(entries.map(\.title), ["Request", "Response", "Headers", "Metadata", "Links", "Events"])
                    XCTAssertEqual(entries.filter(\.checked).map(\.title), [parts.label])
                    XCTAssertEqual(parts.accessibilityLabel(), parts.label)
                    let next = (try XCTUnwrap(InspectorRequestModel.RawPart.allCases.firstIndex(of: part)) + 1) % entries.count
                    entries[next].perform()
                    XCTAssertEqual(request.raw, InspectorRequestModel.RawPart.allCases[next])
                    request.raw = part; raw.refresh(); raw.layoutSubtreeIfNeeded()
                }
                if part == .request || part == .response {
                    let search = try XCTUnwrap(InspectorExpandFixture.descendants(InspectorSearchField.self, in: raw).first)
                    XCTAssertGreaterThanOrEqual(search.frame.width, 120)
                    controls.append(search)
                }
                for control in controls {
                    let frame = control.convert(control.bounds, to: raw)
                    XCTAssertGreaterThanOrEqual(frame.minX, 0, "\(part) at \(width): \(frame)")
                    XCTAssertLessThanOrEqual(frame.maxX, raw.bounds.width, "\(part) at \(width): \(frame)")
                }
            }
        }
    }

    func testRawSearchKeepsFocusAndQueryWhenPartsCollapse() async throws {
        let fixture = try await fixture(), request = fixture.2.request, raw = fixture.3, window = fixture.4
        addTeardownBlock { @MainActor in await self.close(fixture) }
        request.query = "message"; raw.refresh(); raw.layoutSubtreeIfNeeded()
        let search = try XCTUnwrap(InspectorExpandFixture.descendants(InspectorSearchField.self, in: raw).first)
        window.makeKeyAndOrderFront(nil); XCTAssertTrue(window.makeFirstResponder(search.field))
        let editor = search.field.currentEditor()
        for width in [700, 485, 1000] {
            window.setContentSize(NSSize(width: width, height: 600)); raw.compact = width < 900
            raw.layoutSubtreeIfNeeded()
            XCTAssertTrue(search.field.currentEditor() === editor)
            XCTAssertTrue(window.firstResponder === editor)
            XCTAssertEqual(search.field.stringValue, "message"); XCTAssertEqual(request.query, "message")
        }
    }

    func testACopyAlreadyRenderingCannotPublishAfterClear() async throws {
        let fixture = try await fixture(), archive = fixture.1, inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let held = Task {
            try await CapturedBodyWorker.shared.run { entered.signal(); release.wait() }
        }
        defer { release.signal() }
        try await eventually("the held copy worker") { entered.wait(timeout: .now()) == .success }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString("after clear", forType: .string)
        try XCTUnwrap(copyButton(raw)).performClick(nil)
        await Task.yield()
        try await archive.clear(sessionID: "session"); inspector.request.capturesCleared(); inspector.refresh()
        release.signal(); try await held.value
        try await CapturedBodyWorker.shared.run { }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(NSPasteboard.general.string(forType: .string), "after clear")
    }

    func testHeadersCopyIncludesBothDisplayedMaskedSections() async throws {
        let fixture = try await fixture(), inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        inspector.request.raw = .headers; raw.refresh()
        let headers = InspectorExpandFixture.descendants(CapturedHeadersView.self, in: raw)
        XCTAssertEqual(headers.count, 2)
        let copy = try XCTUnwrap(copyButton(raw)); XCTAssertTrue(copy.isEnabled)
        NSPasteboard.general.clearContents(); copy.performClick(nil)
        let text = NSPasteboard.general.string(forType: .string) ?? ""
        XCTAssertTrue(text.contains("Request headers")); XCTAssertTrue(text.contains("Response headers"))
        for section in headers { XCTAssertTrue(text.contains(section.text), "Missing displayed headers: \(section.text)") }
        XCTAssertTrue(text.contains("authorization: Bearer ********-key"))
    }
    func testEmptyHeadersDoNotEnableCopyFromUnrelatedMetadata() async throws {
        let fixture = try await fixture(withHeaders: false), inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        inspector.request.raw = .headers; raw.refresh()
        XCTAssertFalse(inspector.request.metadataText.isEmpty)
        XCTAssertFalse(try XCTUnwrap(copyButton(raw)).isEnabled)
    }

    func testEmptyLinksDoNotEnableCopyFromUnrelatedMetadata() async throws {
        let fixture = try await fixture(), inspector = fixture.2, raw = fixture.3
        addTeardownBlock { @MainActor in await self.close(fixture) }
        inspector.request.raw = .links; raw.refresh()
        let copy = try XCTUnwrap(copyButton(raw))
        try await eventually("empty links disable Copy", timeout: .seconds(2)) { !copy.isEnabled }
    }

    func testGalleryHeadersPurgedBodiesAndTinyCost() async throws {
        guard let path = testEnvironment("PI_APP_INSPECTOR_STORAGE_GALLERY") else { throw XCTSkip("Set PI_APP_INSPECTOR_STORAGE_GALLERY") }
        let folder = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try await fixture(), archive = fixture.1, inspector = fixture.2, raw = fixture.3, window = fixture.4
        addTeardownBlock { @MainActor in await self.close(fixture) }
        let canvas = FillView(.piContent)
        window.contentView = canvas; canvas.addSubview(raw)
        raw.autoresizingMask = [.width, .height]; raw.frame = canvas.bounds
        let now = Date(), filter = DashboardFilter(from: now.addingTimeInterval(-60), until: now.addingTimeInterval(60), bucketCount: 2)
        let report = try await archive.dashboard(filter)
        let chart = PiChartView(spec: ReportChartSpec.make(buckets: report.buckets, metric: .cost, latency: .firstToken, domain: filter.from...filter.until))
        for scene in ["headers", "purged"] {
            if scene == "purged" {
                try await archive.clear(sessionID: "session"); inspector.refresh()
                try await eventually("gallery purge") { inspector.request.metadata["request"]?.object?["state"]?.string == "purged" }
            }
            inspector.request.raw = scene == "headers" ? .headers : .request; raw.refresh()
            if scene == "purged" {
                try await eventually("the unavailable body notice") {
                    InspectorExpandFixture.descendants(CapturedBodyView.self, in: raw).first?.controller.notice.contains("purged") == true
                }
            }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                for width in [1000, 700] {
                    raw.compact = width == 700
                    window.setContentSize(NSSize(width: width, height: 600)); raw.refresh()
                    try capture(canvas, to: folder.appendingPathComponent("\(scene)-\(name)-\(width).png"))
                }
            }
        }
        raw.removeFromSuperview(); canvas.addSubview(chart)
        chart.autoresizingMask = [.width, .height]
        for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
            window.appearance = NSAppearance(named: appearance)
            for width in [1000, 700] {
                window.setContentSize(NSSize(width: width, height: 300))
                chart.frame = canvas.bounds.insetBy(dx: 24, dy: 24)
                try capture(canvas, to: folder.appendingPathComponent("cost-\(name)-\(width).png"))
            }
        }
    }

    func testGalleryRawToolbarAtWindowWidths() async throws {
        guard let path = testEnvironment("PI_APP_INSPECTOR_STORAGE_GALLERY") else { throw XCTSkip("Set PI_APP_INSPECTOR_STORAGE_GALLERY") }
        let folder = URL(fileURLWithPath: path).appendingPathComponent("raw-toolbar")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let fixture = try await fixture(), inspector = fixture.2, raw = fixture.3, window = fixture.4
        addTeardownBlock { @MainActor in await self.close(fixture) }
        let canvas = FillView(.piContent)
        window.contentView = canvas; canvas.addSubview(raw)
        raw.autoresizingMask = [.width, .height]; raw.frame = canvas.bounds
        for part in [InspectorRequestModel.RawPart.request, .response] {
            inspector.request.raw = part; raw.refresh()
            try await eventually("gallery body") { self.copyButton(raw)?.isEnabled == true }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                for width in [1000, 700, 485] {
                    raw.compact = width < 900
                    window.setContentSize(NSSize(width: width, height: 600))
                    try capture(canvas, to: folder.appendingPathComponent("\(part)-\(name)-pane-\(width).png"))
                }
            }
        }
        let full = SessionInspectorView(inspector: inspector)
        window.contentView = full
        for part in [InspectorRequestModel.RawPart.request, .response] {
            inspector.request.raw = part; full.refresh(); full.layoutSubtreeIfNeeded()
            let mounted = try XCTUnwrap(InspectorExpandFixture.descendants(InspectorRawTab.self, in: full).first)
            mounted.refresh()
            try await eventually("full Inspector gallery body") { self.copyButton(mounted)?.isEnabled == true }
            for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
                window.appearance = NSAppearance(named: appearance)
                for size in [NSSize(width: 1000, height: 700), SessionInspectorWindowController.minimumSize] {
                    window.setContentSize(size)
                    try capture(full, to: folder.appendingPathComponent("\(part)-\(name)-window-\(Int(size.width)).png"))
                    XCTAssertGreaterThanOrEqual(mounted.bounds.width, 485)
                    let menu = try XCTUnwrap(InspectorExpandFixture.descendants(PiKit.MenuControl.self, in: mounted).first { $0.accessibilityIdentifier() == "inspector-raw-menu" })
                    XCTAssertLessThanOrEqual(menu.convert(menu.bounds, to: mounted).maxX, mounted.bounds.width)
                }
            }
        }
    }

    private func capture(_ view: NSView, to url: URL) throws {
        view.layoutSubtreeIfNeeded(); view.window?.displayIfNeeded()
        let image = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: image)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: url)
    }

}
