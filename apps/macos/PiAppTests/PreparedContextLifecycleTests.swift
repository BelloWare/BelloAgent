import XCTest
@testable import PiApp

final class PreparedContextLifecycleTests: XCTestCase {
    @MainActor func testExplicitAndAutomaticPreviewsShareOneReadableSnapshotDuringHostStartup() async throws {
        try await withModel { model, id in
            XCTAssertTrue(model.hosts.isEmpty)
            let explicit = Task { try await model.preparedContext(id) }
            let automatic = Task { try await model.preparedContext(id, automatic: true) }
            // Join both even on failure so fixture cleanup never races helper work.
            let explicitResult = await explicit.result, automaticResult = await automatic.result
            let first = try explicitResult.get(), second = try automaticResult.get()
            let revision = try XCTUnwrap(first["revision"]?.string)
            XCTAssertEqual(second["revision"]?.string, revision, "The footer must not replace the inspector's just-returned helper snapshot")
            for result in [first, second] {
                let page = try await model.readPreparedContext(id, revision: try XCTUnwrap(result["revision"]?.string), section: "tools")
                let body = try JSONDecoder().decode(WireValue.self, from: Data(try XCTUnwrap(page["text"]?.string).utf8))
                XCTAssertEqual(body, .array([]))
                XCTAssertEqual(result["dispatched"], .bool(false))
            }
            let attempts = try await model.traces.list(sessionID: id)
            XCTAssertTrue(attempts.isEmpty, "Preparing context sends no model request")
        }
    }

    @MainActor func testNewerDesktopSequenceReusesAnInFlightSnapshotThatAlreadyCoversIt() async throws {
        let requests = PreparedContextRequests(), gate = PreviewGate()
        let started = expectation(description: "First preparation started"), joined = expectation(description: "Newer observer joined")
        let signature = signature("same draft")
        var builds = 0
        let first = Task {
            try await requests.perform("chat", signature: signature, sequence: -1) {
                builds += 1; started.fulfill(); await gate.wait()
                return ["revision": .string("shared"), "seq": .number(3)]
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let newer = Task {
            joined.fulfill()
            return try await requests.perform("chat", signature: signature, sequence: 3) {
                builds += 1
                return ["revision": .string("replacement"), "seq": .number(3)]
            }
        }
        await fulfillment(of: [joined], timeout: 2)
        gate.release()
        let firstValue = try await first.value, newerValue = try await newer.value
        XCTAssertEqual(firstValue["revision"], newerValue["revision"])
        XCTAssertEqual(builds, 1, "Helper startup advancing the desktop sequence must not expire the valid returned revision")
    }

    @MainActor func testChangedInputsWaitForTheOlderPreparationBeforeReplacingItsSnapshot() async throws {
        let requests = PreparedContextRequests(), gate = PreviewGate()
        let started = expectation(description: "Old inputs started"), queued = expectation(description: "New inputs queued")
        let oldSignature = signature("old draft"), newSignature = signature("new draft")
        var retainedRevision = "", completed: [String] = []
        let old = Task {
            try await requests.perform("chat", signature: oldSignature, sequence: 0) {
                started.fulfill(); await gate.wait()
                retainedRevision = "old"; completed.append("old")
                return ["revision": .string("old"), "seq": .number(0)]
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let new = Task {
            queued.fulfill()
            return try await requests.perform("chat", signature: newSignature, sequence: 0) {
                retainedRevision = "new"; completed.append("new")
                return ["revision": .string("new"), "seq": .number(0)]
            }
        }
        await fulfillment(of: [queued], timeout: 2)
        XCTAssertTrue(completed.isEmpty, "The replacement cannot dispatch ahead of the earlier preparation")
        gate.release()
        _ = try await old.value
        let latest = try await new.value
        XCTAssertEqual(completed, ["old", "new"])
        XCTAssertEqual(latest["revision"]?.string, retainedRevision, "A late older result must not replace the new helper snapshot")
    }

    @MainActor func testCancellingOneWaiterKeepsTheSharedSnapshotForTheSurvivingReader() async throws {
        let requests = PreparedContextRequests(), gate = PreviewGate()
        let started = expectation(description: "Automatic preparation started"), joined = expectation(description: "Inspector joined")
        let signature = signature("same draft")
        var builds = 0
        let automatic = Task {
            try await requests.perform("chat", signature: signature, sequence: 0) {
                builds += 1; started.fulfill(); await gate.wait()
                return ["revision": .string("retained"), "seq": .number(0)]
            }
        }
        await fulfillment(of: [started], timeout: 2)
        let inspector = Task {
            joined.fulfill()
            return try await requests.perform("chat", signature: signature, sequence: 0) {
                builds += 1
                return ["revision": .string("replacement"), "seq": .number(0)]
            }
        }
        await fulfillment(of: [joined], timeout: 2)
        automatic.cancel(); gate.release()
        do { _ = try await automatic.value; XCTFail("The cancelled waiter must stop") }
        catch { XCTAssertTrue(error is CancellationError) }
        let result = try await inspector.value
        XCTAssertEqual(result["revision"], .string("retained"))
        XCTAssertEqual(builds, 1, "Cancelling the automatic waiter must not clear a snapshot another reader is awaiting")
    }

    private func signature(_ draft: String) -> AutomaticContextSignature {
        let record = ChatRecord(id: "chat", workspaceID: WorkspaceRecord.scratchID, title: "Preview", path: nil, profileID: "profile")
        return AutomaticContextSignature(binding: ContextPreviewBinding(record), params: ["text": .string(draft)], configurationRevision: 0, directCommand: false)
    }

    @MainActor private func withModel(_ body: (WorkspaceModel, String) async throws -> Void) async throws {
        let base = scratchBase()
        let root = URL(fileURLWithPath: base).appendingPathComponent("prepared-context-lifecycle-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var profile = ProfileRecord(); profile.baseUrl = "http://127.0.0.1:1"; profile.modelId = "preview-only"
        var configuration = VaultConfiguration()
        configuration.profiles = [VaultProfile(profile: profile, apiKey: "synthetic-preview-key")]
        configuration.resources[WorkspaceRecord.scratchID] = .object(["codexHome": .string(root.appendingPathComponent("codex").path)])
        let model = WorkspaceModel(stateRoot: root.appendingPathComponent("state"), vault: ConfigurationVault(storage: MemoryVaultStorage(try JSONEncoder().encode(configuration))))
        func close() async {
            model.cancelAutomaticContext()
            for host in model.hosts.values { try? await host.shutdownAndWait() }
            model.shutdown(); try? await model.traces.close(); await model.store?.close()
            try? FileManager.default.removeItem(at: root)
        }
        do {
            try await model.reloadConfiguration()
            let record = ChatRecord(id: "preview-chat", workspaceID: WorkspaceRecord.scratchID, title: "Preview", path: nil, profileID: profile.id, toolMode: "read-only", connectionTest: true)
            try await model.store?.put(record, kind: "chat", id: record.id)
            let display = SessionDisplay(id: record.id); display.draft = "Inspect this unsent draft"; display.contextSelectionReady = true
            model.chats = [record]; model.displays[record.id] = display
            model.selectedID = record.id; model.focusedSessionID = record.id; model.selected = display
            try await body(model, record.id)
        } catch { await close(); throw error }
        await close()
    }
}

@MainActor private final class PreviewGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    func wait() async {
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
